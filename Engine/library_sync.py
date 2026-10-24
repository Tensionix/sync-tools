"""Verified, scoped MIR library refresh behind SYNC ALL.

Standard library + Git + the application's own rclone. No collector, model,
release, server restore, key import or transport reconfiguration is invoked.
"""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import gzip
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import uuid


class SyncError(ValueError):
    pass


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp-' + uuid.uuid4().hex)
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    os.replace(temporary, path)


def digest(stream):
    value = hashlib.sha256()
    while block := stream.read(1024 * 1024):
        value.update(block)
    return value.hexdigest()


def sha(path):
    with Path(path).open('rb') as stream:
        return digest(stream)


def relative(name):
    """Windows-safe relative name, also enforced in tests on other OSes."""
    if not isinstance(name, str) or not name or '\\' in name or '\x00' in name:
        raise SyncError('Unsafe relative path')
    value = PurePosixPath(name)
    if value.is_absolute() or '..' in value.parts:
        raise SyncError('Absolute path or traversal refused')
    parts = tuple(p for p in value.parts if p != '.')
    for part in parts:
        if (re.search(r'[<>:"|?*\x00-\x1f]', part) or part.endswith((' ', '.'))
                or re.fullmatch(r'(?i)(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?', part)):
            raise SyncError('Windows-unsafe path refused')
    if not parts:
        raise SyncError('Empty relative path')
    return Path(*parts)


def is_link(path):
    info = path.lstat()
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, 'st_file_attributes', 0) & 0x400)


def walk_error(error):
    raise error


def within(root, name):
    if root.exists() and is_link(root):
        raise SyncError('Reparse point at destination root')
    path = root / relative(name)
    if not path.resolve().is_relative_to(root.resolve()):
        raise SyncError('Destination escaped DATA')
    current = path
    while current != root:
        if current.exists() and is_link(current):
            raise SyncError('Reparse point refused: ' + str(current))
        current = current.parent
    return path


def files(root, exclude_git=False):
    result = {}
    if not root.exists():
        return result
    if not root.is_dir() or is_link(root):
        raise SyncError('Expected a real directory: ' + str(root))
    for parent, directories, names in os.walk(root, followlinks=False, onerror=walk_error):
        parent = Path(parent)
        for name in list(directories):
            path = parent / name
            if is_link(path):
                raise SyncError('Local junction/symlink refused: ' + str(path))
            if exclude_git and parent == root and name == '.git':
                directories.remove(name)
        for name in names:
            path = parent / name
            if is_link(path) or not path.is_file():
                raise SyncError('Local special file refused: ' + str(path))
            result[path.relative_to(root).as_posix()] = dict(bytes=path.stat().st_size, sha256=sha(path))
    return result


def tree_state(root):
    if root.is_file():
        if is_link(root):
            raise SyncError('Linked file refused')
        return dict(sha256=sha(root))
    if not root.exists():
        return None
    mapping = files(root)
    directories = sorted(Path(parent, name).relative_to(root).as_posix()
                         for parent, dirs, _ in os.walk(root, onerror=walk_error) for name in dirs)
    return dict(files=mapping, directories=directories)


def run(command, *, input_data=None, env=None, optional=False):
    result = subprocess.run([str(item) for item in command], input=input_data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    if result.returncode and not optional:
        detail = result.stderr.decode('utf-8', errors='replace').strip()[-700:]
        raise SyncError(Path(str(command[0])).name + ' failed (' + str(result.returncode) + '): ' + detail)
    return result


def git(path, *args, env=None, optional=False):
    return run(['git', '--no-optional-locks', '-c', 'core.autocrlf=false', '-c', 'core.hooksPath=', '-C', path, *args],
               env=env, optional=optional)


def text(result):
    return result.stdout.decode('utf-8').strip()


def refs(path):
    return sorted(text(git(path, 'for-each-ref', '--format=%(objectname) %(refname)')).splitlines())


def stable_state(root):
    """Ignore only a Git index stat-cache refresh, never staged content/flags.

    The physical index is still archived and verified byte-for-byte. GUI Git
    status can refresh its timestamps while the backup is being prepared.
    """
    state = tree_state(root)
    if state and root.is_dir() and (root / '.git').is_dir() and (root / '.git/index').is_file():
        result = git(root, 'ls-files', '--stage', '-v', '-z', optional=True)
        if result.returncode == 0:
            state['files'].pop('.git/index', None)
            state['gitIndex'] = hashlib.sha256(result.stdout).hexdigest()
    return state


# What a value of the template looks like: SYNC ALL refuses a plan that still holds one.
PLACEHOLDER = re.compile(r'<[^<>]+>')


def placeholders(value, key=''):
    """The values of a plan still shaped as <...>; keys starting with _ are comments."""
    if key.startswith('_'):
        return []
    if isinstance(value, dict):
        return [found for name, item in value.items() for found in placeholders(item, name)]
    if isinstance(value, list):
        return [found for item in value for found in placeholders(item)]
    return [value] if isinstance(value, str) and PLACEHOLDER.search(value) else []


def load_plan(path):
    """The plan of SYNC ALL: config/mirror.json of DATA, version 2.

    The servers, their folders, the bucket and the repositories are the household's: they live in
    DATA only. The program carries a template without values (config/mirror.sample.json) and builds
    no plan from it - nor finishes an old version 1 one with its own defaults: such a plan carried
    the whole map of MAIN VPS inside the public program (the owner, 23.10.2026).
    """
    if not path.is_file():
        raise SyncError('No SYNC ALL plan in DATA (config/mirror.json): copy it from the DATA of a machine '
                        'where SYNC ALL ran, or fill in the template config/mirror.sample.json of the program')
    plan = read_json(path)
    if plan.get('version') != 2:
        raise SyncError('The SYNC ALL plan in DATA is version 1: SYNC ALL needs version 2 - copy config/mirror.json '
                        'from the DATA of a machine where SYNC ALL ran (this plan is not changed)')
    if placeholders(plan):
        raise SyncError('The SYNC ALL plan still holds values of the template, ' + ', '.join(sorted(set(placeholders(plan)))[:3])
                        + ': fill them in config/mirror.json of DATA')
    if not plan.get('sources') or not plan.get('forgejo', {}).get('owners'):
        raise SyncError('Incomplete library plan')
    # MIR is the only mode. protectedLocal is not filled in by the program: the old default named a
    # folder of one household, and a plan silently without it would let MIR remove those secrets.
    if plan.setdefault('mode', 'mir') != 'mir':
        raise SyncError('SYNC ALL knows the mode "mir" only')
    if not isinstance(plan.get('protectedLocal'), dict):
        raise SyncError('The SYNC ALL plan must name its protectedLocal - the local paths MIR keeps as they are '
                        '(may be empty: {})')
    names = set()
    for source in plan['sources']:
        folder = relative(source['folder']).as_posix()
        if folder.split('/')[0].casefold() in {'tunnel', 'config', 'snapshots', 'recovery', '._runtime', 'repositories', 'forgejo mirror'}:
            raise SyncError('Source overlaps protected DATA: ' + folder)
        if any(folder.casefold() == name or folder.casefold().startswith(name + '/')
               or name.startswith(folder.casefold() + '/') for name in names):
            raise SyncError('Duplicate/overlapping source folder')
        names.add(folder.casefold())
        if source.get('from') not in {'git', 'payload', 'snapshot', 'server'}:
            raise SyncError('Unknown source kind')
    return plan


class Transport:
    def __init__(self, app, data, plan, rclone, ssh, offline_catalog=None):
        self.app, self.data, self.plan = app, data, plan
        self.rclone, self.ssh, self.offline_catalog = rclone, ssh, offline_catalog
        self.git_env = os.environ.copy()
        self.git_env.update(GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1')
        self.ssh_command = ''
        if not offline_catalog:
            config = plan['forgejo']
            identity = within(data, config['identity'])
            known_hosts = within(data, config['knownHosts'])
            if not identity.is_file() or not known_hosts.is_file():
                raise SyncError('Forgejo identity or trusted known_hosts is missing in DATA; use IMPORT KEYS')
            self.ssh_command = shlex.join([str(ssh).replace('\\', '/'), '-i', identity.as_posix(),
                '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
                '-o', 'UpdateHostKeys=no', '-o', 'ConnectTimeout=20',
                # -o values are parsed once more by OpenSSH's config tokenizer:
                # shell quoting alone loses a DATA path containing spaces.
                '-o', 'UserKnownHostsFile="' + known_hosts.as_posix() + '"', '-J', plan['server']])
            self.git_env['GIT_SSH_COMMAND'] = self.ssh_command

    def r2(self, *args):
        return text(run([self.rclone, '--config', self.data / 'config/rclone/rclone.conf',
                         '--cache-dir', self.data / '._runtime/rclone-cache', *args]))

    def catalog(self):
        if self.offline_catalog:
            value = read_json(self.offline_catalog)
        else:
            script = (self.app / 'Engine/library_inventory.py').read_bytes()
            command = 'python3 - ' + shlex.quote(json.dumps(self.plan, ensure_ascii=True))
            value = json.loads(text(run([self.ssh, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                                        '-o', 'UpdateHostKeys=no', '-o', 'ConnectTimeout=20',
                                        self.plan['server'], command], input_data=script)))
        validate_catalog(value)
        return value

    def url(self, item):
        if self.offline_catalog:
            return item['localPath']
        return self.plan['forgejo']['url'].rstrip('/') + '/' + item['repository']

    def latest_snapshot(self, stage):
        bucket = self.plan['bucket'].rstrip('/')
        candidates = []
        for category, pattern in [('daily', r'\d{4}-\d{2}-\d{2}'),
                                  ('manual', r'\d{4}-\d{2}-\d{2}T[0-9TZ-]+-\d+')]:
            names = self.r2('lsf', bucket + '/' + category, '--dirs-only').splitlines()
            names = sorted((name.strip('/') for name in names if re.fullmatch(pattern, name.strip('/'))), reverse=True)
            if names:
                source = bucket + '/' + category + '/' + names[0] + '/audion-main-server-recovery.tar.gz'
                item = json.loads(self.r2('lsjson', source, '--stat'))
                if not item or item.get('Size', 0) <= 0:
                    raise SyncError('Latest snapshot object is empty or unavailable')
                candidates.append((item['ModTime'], source))
        if not candidates:
            raise SyncError('No daily/manual recovery snapshot found')
        source = max(candidates)[1]
        print('DOWNLOAD:', source, flush=True)
        archive = stage / 'download.tar.gz'
        self.r2('copyto', source, str(archive))
        self.r2('copyto', source + '.sha256', str(archive) + '.sha256')
        return archive, source


def validate_catalog(value):
    if not value.get('repositories'):
        raise SyncError('Empty repository catalog')
    seen = set()
    for item in value['repositories']:
        name = item['repository']
        if not re.fullmatch(r'[a-zA-Z0-9_-]+/[a-zA-Z0-9_.-]+\.git', name) or name.casefold() in seen:
            raise SyncError('Invalid or duplicate repository identity')
        seen.add(name.casefold())
        expected = {}
        for entry in item['refs']:
            if (not re.fullmatch(r'[0-9a-f]{40,64}', entry['oid']) or not entry['ref'].startswith('refs/')
                    or entry['ref'] in expected):
                raise SyncError('Invalid repository refs')
            expected[entry['ref']] = entry['oid']
        if not item['headRef'].startswith('refs/heads/') or (expected and expected.get(item['headRef']) != item['head']):
            raise SyncError('Invalid repository default HEAD')


def unpack_snapshot(archive, target, plan):
    sum_path = Path(str(archive) + '.sha256')
    if not sum_path.is_file():
        raise SyncError('Snapshot checksum file is missing')
    expected = sum_path.read_text(encoding='utf-8-sig').split()
    actual = sha(archive)
    if not expected or not re.fullmatch(r'[0-9a-fA-F]{64}', expected[0]) or expected[0].lower() != actual:
        raise SyncError('Snapshot checksum mismatch')
    # Tar iteration can stop at its end marker before gzip's CRC/footer. Read
    # the complete stream too, so a self-checksummed truncated gzip is refused.
    with gzip.open(archive, 'rb') as compressed:
        digest(compressed)
    target.mkdir()
    seen, regular = set(), set()
    with tarfile.open(archive, 'r:gz') as outer:
        for member in outer:
            path = relative(member.name)
            if path.parts[0] != 'audion-main-server-recovery':
                raise SyncError('Unexpected recovery archive root')
            if len(path.parts) == 1:
                if not member.isdir():
                    raise SyncError('Invalid recovery root')
                continue
            name = Path(*path.parts[1:]).as_posix()
            key = name.casefold()
            if key in seen:
                raise SyncError('Duplicate/case-colliding archive member')
            seen.add(key)
            destination = within(target, name)
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                regular.add(name)
                destination.parent.mkdir(parents=True, exist_ok=True)
                with outer.extractfile(member) as source, destination.open('xb') as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
            else:
                raise SyncError('Outer archive links/special files are refused')
    declared = set()
    for line in (target / 'manifest.sha256').read_text().splitlines():
        match = re.fullmatch(r'([a-f0-9]{64}) [ *](.+)', line)
        if not match:
            raise SyncError('Invalid inner manifest line')
        name = relative(match[2]).as_posix()
        if name in declared or not (target / name).is_file() or sha(target / name) != match[1]:
            raise SyncError('Inner manifest missing/duplicate/checksum mismatch: ' + name)
        declared.add(name)
    if declared != regular - {'manifest.sha256'}:
        raise SyncError('Inner manifest does not cover every recovery file')
    inventory = read_json(target / 'payload/operational-inventory.json')
    if (inventory.get('format') != 'operational-inventory/1' or inventory.get('errors')
            or not inventory.get('records') or not inventory.get('git_heads')):
        raise SyncError('Missing or failed operational inventory')
    required = {'git-forgejo.tar.gz', 'operational-inventory.json'}
    for source in plan['sources']:
        if source.get('part'):
            required.add(source['part'])
        required.update(overlay['part'] for overlay in source.get('overlays', []))
    payloads = {path.name: dict(bytes=path.stat().st_size, sha256=sha(path))
                for path in (target / 'payload').iterdir() if path.is_file()}
    if required - payloads.keys():
        raise SyncError('Required recovery payload is missing')
    verify_coverage(target, plan, inventory)
    for name in payloads:
        if name.endswith('.tar.gz'):
            with gzip.open(target / 'payload' / name, 'rb') as compressed:
                digest(compressed)
            # Inspect every new payload, not just the hard-coded source views.
            with tarfile.open(target / 'payload' / name, 'r:gz') as nested:
                count = 0
                for member in nested:
                    if '..' in PurePosixPath(member.name).parts:
                        raise SyncError('Traversal in nested archive')
                    if member.isfile():
                        with nested.extractfile(member) as body:
                            digest(body)
                        count += 1
                if not count:
                    raise SyncError('Empty nested payload: ' + name)
    return dict(sha256=actual, payloads=payloads, operationalFiles=len(inventory['records']),
                snapshotGitHeads=inventory['git_heads'])


def verify_coverage(recovery, plan, inventory):
    """Compare installed bytes + Unix metadata without executing archive code."""
    manifest = (recovery / 'manifest.txt').read_text()
    match = re.search(r'^host: (.+)$', manifest, re.M)
    if not match:
        raise SyncError('Snapshot host is missing')
    main_host = match[1].strip()
    second_hosts = {item['host'] for item in inventory['records']} - {main_host}
    if len(second_hosts) > 1:
        raise SyncError('Ambiguous secondary host in operational inventory')
    hosts = {'main': main_host, 'second': next(iter(second_hosts), '')}
    index = {}
    for layout in plan['coverage']:
        path = recovery / 'payload' / layout['part']
        if not path.is_file():
            continue
        with tarfile.open(path, 'r:gz') as nested:
            for member in nested:
                if member.isdir():
                    continue
                if '..' in PurePosixPath(member.name).parts:
                    raise SyncError('Traversal in operational payload')
                name = '/' + '/'.join(p for p in (layout['prefix'].strip('/'), member.name.removeprefix('./').lstrip('/')) if p)
                entry = dict(mode=member.mode, uid=member.uid, gid=member.gid)
                if member.isfile():
                    with nested.extractfile(member) as body:
                        entry.update(type='file', sha256=digest(body))
                elif member.issym():
                    entry.update(type='symlink', target=member.linkname)
                elif member.islnk():
                    link = '/' + '/'.join(p for p in (layout['prefix'].strip('/'), member.linkname.removeprefix('./').lstrip('/')) if p)
                    entry.update(type='hardlink', target=link)
                else:
                    continue
                key = (hosts[layout['role']], name)
                previous = index.get(key)
                if previous and entry['type'] == 'hardlink' and entry['target'] == name:
                    continue
                if previous and previous != entry and previous['type'] != 'hardlink' and entry['type'] != 'hardlink':
                    raise SyncError('Conflicting operational archive records')
                if not previous or entry['type'] != 'hardlink':
                    index[key] = entry
    def resolve(key, seen=None):
        seen = set() if seen is None else seen
        if key in seen:
            raise SyncError('Archive hardlink cycle')
        seen.add(key)
        entry = index.get(key)
        if entry and entry['type'] == 'hardlink':
            target = resolve((key[0], entry['target']), seen)
            if target:
                return dict(target, mode=entry['mode'], uid=entry['uid'], gid=entry['gid'])
        return entry
    for wanted in inventory['records']:
        expected = {k: v for k, v in wanted.items() if k not in {'host', 'path'}}
        if resolve((wanted['host'], wanted['path'])) != expected:
            raise SyncError('Operational bytes/metadata missing: ' + wanted['path'])
    for timer in inventory.get('enabled_timers', []):
        if '/' in timer or not timer.endswith('.timer') or not resolve((main_host, '/etc/systemd/system/' + timer)):
            raise SyncError('Enabled timer is missing from backup')
    heads = {}
    with tarfile.open(recovery / 'payload/git-forgejo.tar.gz', 'r:gz') as archive:
        loose = {}
        for member in archive:
            name = member.name.removeprefix('./')
            if not member.isfile() or not name.startswith('repos/'):
                continue
            if name.endswith('.git/packed-refs'):
                repo = name[6:].removesuffix('/packed-refs')
                for line in archive.extractfile(member).read().decode('ascii').splitlines():
                    if line and not line.startswith(('#', '^')):
                        oid, ref = line.split()
                        if ref.startswith('refs/heads/'):
                            heads[(repo, ref[11:])] = oid
            elif '.git/refs/heads/' in name:
                repo, branch = name[6:].split('/refs/heads/', 1)
                loose[(repo, branch)] = archive.extractfile(member).read().decode('ascii').strip()
        heads.update(loose)
    for item in inventory['git_heads']:
        if heads.get((item['repository'], item['branch'])) != item['head']:
            raise SyncError('Snapshot is missing an active Git HEAD')


def overlay_payload(recovery, source, stage):
    restored = {}
    for overlay in source.get('overlays', []):
        count = 0
        with tarfile.open(recovery / 'payload' / overlay['part'], 'r:gz') as archive:
            seen = set()
            for member in archive:
                raw = PurePosixPath(member.name)
                if '..' in raw.parts:
                    raise SyncError('Traversal in publication payload')
                # Absolute Linux paths are selected BEFORE stripping the root.
                parts = tuple(p for p in raw.parts if p not in {'/', '.'})
                if not any(parts[:len(PurePosixPath(prefix).parts)] == PurePosixPath(prefix).parts
                           for prefix in overlay['prefixes']):
                    continue
                suffix = parts[overlay.get('strip', 0):]
                if not suffix:
                    continue
                name = relative('/'.join(suffix)).as_posix()
                if name.casefold() in seen:
                    raise SyncError('Duplicate publication entry')
                seen.add(name.casefold())
                destination = within(stage, name)
                if member.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(member) as body, destination.open('wb') as output:
                        shutil.copyfileobj(body, output, 1024 * 1024)
                    restored[name] = sha(destination)
                    count += 1
                else:
                    raise SyncError('Publication links/special files refused')
        if overlay.get('required', True) and not count:
            raise SyncError('Expected publication data is missing: ' + source['folder'])
    return restored




def verified_cache(data, stage, mirror_name, item):
    """Reuse only complete, self-contained local mirrors with exactly current refs."""
    wanted = sorted(entry['oid'] + ' ' + entry['ref'] for entry in item['refs'])
    candidates = [within(data, 'Forgejo Mirror/' + mirror_name)]
    candidates += [within(parent, 'library/Forgejo Mirror/' + mirror_name)
                   for parent in sorted(within(data, 'Recovery/sync-all').glob('sync-all-*'), reverse=True)
                   if parent.is_dir() and parent != stage]
    for candidate in candidates:
        if not (candidate / 'HEAD').is_file() or (candidate / 'objects/info/alternates').exists():
            continue
        try:
            if (refs(candidate) == wanted and text(git(candidate, 'rev-parse', '--verify', 'HEAD', optional=True)) == item['head']
                    and text(git(candidate, 'rev-parse', '--is-bare-repository', optional=True)) == 'true'
                    and git(candidate, 'fsck', '--full', optional=True).returncode == 0):
                return candidate
        except SyncError:
            continue  # A broken old cache must not stop a clean remote download.
    return None


def verify_checkout(checkout, head):
    if not head:
        return
    seen = set()
    for entry in git(checkout, 'ls-tree', '-rz', 'HEAD').stdout.split(b'\0'):
        if not entry:
            continue
        mode, _, _ = entry.split(b'\t', 1)[0].split()
        name = entry.split(b'\t', 1)[1].decode('utf-8')
        relative(name)
        if name.casefold() in seen or mode == b'160000':
            raise SyncError('Case-colliding source paths or unbacked submodule: ' + checkout.name)
        seen.add(name.casefold())
        if not (checkout / name).is_file():
            raise SyncError('Git checkout is missing a source file: ' + name)
    if git(checkout, 'diff', '--no-ext-diff', '--no-textconv', '--quiet', 'HEAD', '--', optional=True).returncode:
        raise SyncError('Git checkout differs from its source before local data was applied')


def copy_protected(old, incoming, names):
    protected = {}
    for name in names:
        if relative(name).parts[0] == '.git':
            raise SyncError('Git metadata cannot be a protected local subtree')
        source = within(old, name)
        destination = within(incoming, name)
        if not source.exists():
            continue
        if source.is_dir():
            files(source)
            shutil.copytree(source, destination, dirs_exist_ok=True)
        else:
            if is_link(source):
                raise SyncError('Protected link refused')
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        protected[name] = tree_state(destination)
        with (incoming / '.git/info/exclude').open('a', encoding='utf-8') as output:
            output.write('\n/' + name.rstrip('/') + ('/' if source.is_dir() else '') + '\n')
    return protected


def stage_library(catalog, plan, transport, data, recovery, stage, only):
    library = stage / 'library'
    library.mkdir()
    mirror = library / 'Forgejo Mirror'
    mirror.mkdir()
    sources = {s['repository']: s for s in plan['sources'] if s['from'] == 'git'}
    result, names, preconditions = [], set(), {
        'Forgejo Mirror': tree_state(within(data, 'Forgejo Mirror')),
        'Repositories': stable_state(within(data, 'Repositories'))}
    for item in catalog['repositories']:
        identity = item['repository']
        owner, repository = identity.split('/')
        name = repository if len(plan['forgejo']['owners']) == 1 else identity
        target = within(mirror, name)
        target.parent.mkdir(parents=True, exist_ok=True)
        print('GIT:', identity, flush=True)
        cache = verified_cache(data, stage, name, item)
        if cache:
            print('  reusing verified local Git objects', flush=True)
        run(['git', '-c', 'core.autocrlf=false', '-c', 'core.hooksPath=', 'clone', '--quiet', '--mirror', '--no-hardlinks',
             cache or transport.url(item), target], env=transport.git_env)
        git(target, 'remote', 'set-url', 'origin', transport.url(item))
        git(target, 'symbolic-ref', 'HEAD', item['headRef'])
        git(target, 'fsck', '--full')
        wanted = sorted(entry['oid'] + ' ' + entry['ref'] for entry in item['refs'])
        if refs(target) != wanted or text(git(target, 'rev-parse', '--verify', 'HEAD', optional=True)) != item['head']:
            raise SyncError('Forgejo changed during clone: ' + identity)
        if transport.ssh_command:
            git(target, 'config', 'core.sshCommand', transport.ssh_command)
        source = sources.get(identity) or dict(repository=identity, folder='Repositories/' + owner + '/' + repository[:-4],
                                               **{'from': 'git'})
        folder = source['folder']
        if folder.casefold() in names:
            raise SyncError('Repository destination collision')
        names.add(folder.casefold())
        if only and folder not in only and not ('Repositories' in only and folder.startswith('Repositories/')):
            continue
        old = within(data, folder)
        preconditions[folder] = stable_state(old)
        checkout = within(library, folder)
        checkout.parent.mkdir(parents=True, exist_ok=True)
        branch = item.get('activeBranch') or item['headRef'][11:]
        current = item.get('activeHead') or item['head']
        command = ['git', '-c', 'core.autocrlf=false', '-c', 'core.hooksPath=', 'clone', '--quiet', '--no-hardlinks']
        if current:
            command += ['--branch', branch]
        run(command + [target, checkout])
        verify_checkout(checkout, current)
        git(checkout, 'remote', 'set-url', 'origin', transport.url(item))
        if transport.ssh_command:
            git(checkout, 'config', 'core.sshCommand', transport.ssh_command)
        overlays = overlay_payload(recovery, source, checkout)
        protected = copy_protected(old, checkout, plan.get('protectedLocal', {}).get(folder, []))
        git(checkout, 'fsck', '--full')
        if current and text(git(checkout, 'rev-parse', 'HEAD')) != current:
            raise SyncError('Working checkout HEAD mismatch')
        receipt = dict(repository=identity, head=current, branch=branch, publications=overlays,
                       mode='mir', protectedLocal=protected)
        write_json(checkout / 'LOCAL-COPY-INFO.json', receipt)
        exclude = checkout / '.git/info/exclude'
        if '/LOCAL-COPY-INFO.json' not in exclude.read_text(encoding='utf-8').splitlines():
            with exclude.open('a', encoding='utf-8') as output:
                output.write('\n/LOCAL-COPY-INFO.json\n')
        result.append(dict(folder=folder, **receipt))
    for source in plan['sources']:
        if source['from'] == 'git' or only and source['folder'] not in only:
            continue
        folder = source['folder']
        preconditions[folder] = tree_state(within(data, folder))
        destination = within(library, folder)
        destination.mkdir(parents=True)
        if source['from'] != 'payload':
            raise SyncError('Custom v1 source needs an explicit v2 Git/payload mapping (old config is preserved): ' + folder)
        incoming = recovery / 'payload' / source['part']
        shutil.copy2(incoming, within(destination, source.get('filename', source['part'])))
        result.append(dict(folder=folder, payload=source['part']))
    known = {row['folder'] for row in result} | {'Forgejo Mirror', 'Snapshots', 'Repositories'}
    if only - known:
        raise SyncError('Unknown -Only folders: ' + ', '.join(sorted(only - known)))
    write_json(mirror / 'INDEX.json', catalog)
    return library, result, [], preconditions


@contextmanager
def data_lock(data):
    path = within(data, 'config/sync-all.lock')
    legacy = within(data, '._runtime/sync-all.lock')
    path.parent.mkdir(parents=True, exist_ok=True)
    streams = []
    try:
        for target in [path] + ([legacy] if legacy.exists() else []):
            stream = target.open('a+b')
            streams.append(stream)
            stream.seek(0)
            if os.name == 'nt':
                import msvcrt
                if target.stat().st_size == 0:
                    stream.write(b'0'); stream.flush(); stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        for held in streams:
            held.close()
        raise SyncError('Another SYNC ALL is already using this DATA')
    try:
        yield
    finally:
        for held in streams:
            held.close()


def protect(path):
    if os.name == 'nt':
        sid = text(run(['whoami', '/user', '/fo', 'csv', '/nh'])).split(',')[-1].strip('"')
        run(['icacls.exe', path, '/inheritance:r', '/grant:r', '*' + sid + ':(OI)(CI)(F)',
             '*S-1-5-18:(OI)(CI)(F)', '*S-1-5-32-544:(OI)(CI)(F)', '/Q'])
    else:
        path.chmod(0o700)


def commit_swaps(data, stage, replacements, preconditions=None):
    """Same-volume renames + write-ahead journal. No recursive deletion."""
    journal_path = stage / 'transaction.json'
    before_root = stage / 'before'
    before_root.mkdir()
    journal = dict(version=1, status='prepared', replacements=[])
    for name, incoming in replacements:
        destination = within(data, name)
        old_state = tree_state(destination)
        stable = stable_state(destination)
        if preconditions and name in preconditions and stable != preconditions[name]:
            expected_files = (preconditions[name] or {}).get('files', {})
            actual_files = (stable or {}).get('files', {})
            changed = [p for p in expected_files.keys() | actual_files.keys() if expected_files.get(p) != actual_files.get(p)]
            if (stable or {}).get('gitIndex') != (preconditions[name] or {}).get('gitIndex'):
                changed.append('.git/index (staged content/flags)')
            raise SyncError('Local DATA changed during staging: ' + name + ' [' + ', '.join(sorted(changed)[:10]) + ']')
        journal['replacements'].append(dict(name=name, incoming=str(incoming.relative_to(stage).as_posix()),
            old=old_state, new=tree_state(incoming), movedOld=False, installed=False))
    write_json(journal_path, journal)
    try:
        for row in journal['replacements']:
            destination = within(data, row['name'])
            incoming = within(stage, row['incoming'])
            saved = within(before_root, row['name'])
            destination.parent.mkdir(parents=True, exist_ok=True)
            saved.parent.mkdir(parents=True, exist_ok=True)
            if tree_state(destination) != row['old']:
                raise SyncError('Local DATA changed before replacement: ' + row['name'])
            row['intent'] = 'move-old'; write_json(journal_path, journal)
            if destination.exists():
                os.replace(destination, saved)
                row['movedOld'] = True
                if tree_state(saved) != row['old']:
                    raise SyncError('Archived original verification failed')
            row['intent'] = 'install'; write_json(journal_path, journal)
            os.replace(incoming, destination)
            row['installed'] = True
            if tree_state(destination) != row['new']:
                raise SyncError('Installed copy verification failed')
            row['intent'] = 'done'; write_json(journal_path, journal)
        journal['status'] = 'complete'
        write_json(journal_path, journal)
    except BaseException:
        rollback(data, stage)
        raise


def rollback(data, stage):
    journal_path = stage / 'transaction.json'
    journal = read_json(journal_path)
    if journal['status'] in {'complete', 'rolled-back'}:
        return
    for row in reversed(journal['replacements']):
        destination = within(data, row['name'])
        saved = within(stage / 'before', row['name'])
        incoming = within(stage, row['incoming'])
        installed = not incoming.exists() and destination.exists() and row.get('intent') in {'install', 'done'}
        if installed:
            if tree_state(destination) != row['new']:
                raise SyncError('Interrupted copy was edited; manual recovery required: ' + str(stage))
            incoming.parent.mkdir(parents=True, exist_ok=True)
            os.replace(destination, incoming)
        if saved.exists():
            if destination.exists():
                raise SyncError('Recovery target occupied; nothing overwritten: ' + row['name'])
            os.replace(saved, destination)
    journal['status'] = 'rolled-back'
    write_json(journal_path, journal)


def migrate_legacy_sync(data):
    """Move old journals with their exact before/incoming trees before scratch can be cleaned."""
    for old in sorted(within(data, '._runtime').glob('sync-all-*')):
        if not re.fullmatch(r'sync-all-\d{8}T\d{6}Z-[0-9a-f]{8}', old.name) or not old.is_dir():
            continue
        tree = tree_state(old)  # rejects links and unreadable files before any move
        target = within(data, 'Recovery/sync-all/' + old.name)
        if target.exists():
            raise SyncError('Legacy transaction conflicts with durable recovery; neither copy changed')
        target.parent.mkdir(parents=True, exist_ok=True)
        protect(within(data, 'Recovery'))
        os.replace(old, target)
        if tree_state(target) != tree:
            os.replace(target, old)
            raise SyncError('Legacy transaction migration verification failed')


def recover_pending(data):
    migrate_legacy_sync(data)
    for path in sorted(within(data, 'Recovery/sync-all').glob('sync-all-*/transaction.json')):
        if read_json(path)['status'] not in {'complete', 'rolled-back'}:
            rollback(data, path.parent)
            print('RECOVERED interrupted transaction:', path.parent.name, flush=True)


def delete_owned(path, parent):
    """Delete one explicitly resolved owned scratch target, never its parent."""
    path, parent = Path(path).absolute(), Path(parent).resolve()
    if path.parent.resolve() != parent or path.resolve().parent != parent or is_link(path):
        raise SyncError('Unsafe cleanup target refused')
    if path.is_dir():
        for directory, folders, names in os.walk(path, followlinks=False, onerror=walk_error):
            for name in folders + names:
                if is_link(Path(directory) / name):
                    raise SyncError('Cleanup refuses a nested reparse point')
        def retry(function, target, error):
            target = Path(target)
            if not target.resolve().is_relative_to(path.resolve()) or is_link(target):
                raise SyncError('Cleanup retry escaped its target')
            os.chmod(target, 0o700)
            function(target)
        shutil.rmtree(path, onerror=retry)
    else:
        path.unlink()


def cleanup_mir(data, stage):
    """A completed MIR keeps proofs, not generations of old source folders."""
    if read_json(stage / 'transaction.json')['status'] != 'complete':
        raise SyncError('Cleanup requires a successfully verified transaction')
    runtime = within(data, 'Recovery/sync-all')
    removed = []
    for old in sorted(runtime.iterdir()):
        if old == stage or not re.fullmatch(r'sync-all-\d{8}T\d{6}Z-[0-9a-f]{8}', old.name):
            continue
        if not old.is_dir() or is_link(old):
            raise SyncError('Unknown MIR cache entry refused')
        journal = old / 'transaction.json'
        if journal.is_file():
            if read_json(journal)['status'] not in {'complete', 'rolled-back'}:
                raise SyncError('Unfinished transaction must be recovered before cleanup')
        elif not (old / 'failure.json').is_file():
            raise SyncError('Unrecognized MIR cache directory refused')
        delete_owned(old, runtime)
        removed.append(old.name)
    for child in list(stage.iterdir()):
        if (child.name in {'before', 'library', 'recovery'} or child.name.startswith('download.tar.gz')
                or re.fullmatch(r'audion-main-server-recovery-[a-f0-9]{16}\.tar\.gz(?:\.sha256)?', child.name)):
            delete_owned(child, stage)
            removed.append(stage.name + '/' + child.name)
    return removed


def execute(args):
    app, data = Path(args.app).resolve(), Path(args.root).absolute()
    if not data.is_dir() or data.parent == data or is_link(data):
        raise SyncError('DATA must be an existing real, non-root directory')
    plan_path = within(data, 'config/mirror.json')
    plan_before = tree_state(plan_path)
    plan = load_plan(plan_path)
    only = {name.strip() for name in args.only.split(',') if name.strip()}
    if args.only and not only:
        raise SyncError('Empty -Only selection refused')
    transport = Transport(app, data, plan, args.rclone, args.ssh, args.catalog)
    print('INVENTORY: reading MAIN VPS repository catalog', flush=True)
    catalog = transport.catalog()
    if args.what_if:
        print('DRY RUN: no local files/configs/ACLs are changed')
        print('Discovered repositories:', len(catalog['repositories']))
        print('Recovery: latest daily/manual, all payloads; old snapshots are retained')
        print('MIR: verified server copies replace library folders; local extras and successful rollback copies are removed')
        for item in catalog['repositories']:
            print(' ', item['repository'], item.get('activeHead', item['head'])[:12])
        return
    with data_lock(data):
        recover_pending(data)
        # Recovery may have put back a plan that a killed transaction had already
        # replaced. Use the restored settings, not the pre-lock copy.
        if tree_state(plan_path) != plan_before:
            plan_before = tree_state(plan_path)
            plan = load_plan(plan_path)
            transport = Transport(app, data, plan, args.rclone, args.ssh, args.catalog)
            catalog = transport.catalog()
        identifier = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8]
        stage = within(data, 'Recovery/sync-all/sync-all-' + identifier)
        stage.mkdir(parents=True)
        protect(within(data, 'Recovery'))
        protect(stage)
        try:
            snapshot, origin = (Path(args.snapshot).resolve(), 'local verified recovery') if args.snapshot else transport.latest_snapshot(stage)
            recovery = stage / 'recovery'
            proof = unpack_snapshot(snapshot, recovery, plan)
            print('RECOVERY: verified', len(proof['payloads']), 'payloads,', proof['operationalFiles'], 'operational files', flush=True)
            print('MIR: server versions win; only explicit protected local paths survive', flush=True)
            library, projects, retained, preconditions = stage_library(catalog, plan, transport, data, recovery, stage, only)
            write_json(stage / 'preconditions.json', preconditions)
            if transport.catalog() != catalog:
                raise SyncError('Server Git inventory changed during SYNC ALL; retry safely')
            if tree_state(plan_path) != plan_before:
                raise SyncError('Library plan changed during staging')
            stamp = proof['sha256'][:16]
            shelf_name = 'audion-main-server-recovery-' + stamp + '.tar.gz'
            incoming_archive = stage / shelf_name
            shutil.copy2(snapshot, incoming_archive)
            incoming_sum = stage / (shelf_name + '.sha256')
            incoming_sum.write_text(proof['sha256'] + '  ' + shelf_name + '\n', encoding='ascii')
            replacements = []
            for name, incoming in [('Snapshots/' + shelf_name, incoming_archive),
                                   ('Snapshots/' + shelf_name + '.sha256', incoming_sum),
                                   ('Snapshots/Recovery-' + stamp, recovery)]:
                existing = within(data, name)
                if existing.is_file() and sha(existing) == sha(incoming):
                    continue
                if existing.is_dir() and tree_state(existing) == tree_state(incoming):
                    continue
                replacements.append((name, incoming))
            mirrors_installed = not only or 'Forgejo Mirror' in only
            if mirrors_installed:
                replacements.append(('Forgejo Mirror', library / 'Forgejo Mirror'))
            group_repositories = not only or 'Repositories' in only
            if group_repositories:
                (library / 'Repositories').mkdir(exist_ok=True)
                replacements.append(('Repositories', library / 'Repositories'))
            replacements.extend((row['folder'], within(library, row['folder'])) for row in projects
                                if not group_repositories or not row['folder'].startswith('Repositories/'))
            report = dict(version=2, status='verified', createdAt=datetime.now(timezone.utc).isoformat(),
                selected=sorted(only), snapshot=dict(source=origin, **proof), mirrors=catalog['repositories'],
                mode='mir', protectedLocal=plan.get('protectedLocal', {}),
                mirrorsInstalled=mirrors_installed, projects=projects, retainedMirrorEntries=retained,
                rollbackRetention='temporary until successful verification',
                boundary='Server recovery + Forgejo/library only; other R2 buckets, KV/DO are not claimed',
                archive=str(within(data, 'Snapshots/' + shelf_name)))
            report_path = stage / 'BACKUP-CATALOG.json'
            write_json(report_path, report)
            replacements.append(('BACKUP-CATALOG.json', report_path))
            markdown = stage / 'BACKUP-CATALOG.md'
            markdown.write_text('# Audion backup library\n\nSYNC ALL: verified ' + report['createdAt'] + '\n\n' +
                f"{len(catalog['repositories'])} Git mirrors checked (installed: {mirrors_installed}); " +
                f"{len(projects)} working folders; {len(proof['payloads'])} recovery payloads; " +
                f"{proof['operationalFiles']} operational records.\n\n" +
                'Canonical archive: `' + report['archive'] + '`\n\n' +
                'Mode: MIR. Server copies replace managed folders, including local extras and old Git state. '
                'Only explicit protectedLocal paths survive. Temporary rollback copies and previous SYNC ALL caches '
                'are removed after successful verification. Recovery snapshots and connection settings are not removed.\n\n' +
                'The unpacked recovery view is for reading. Restore Unix modes/owners from the original tar, not Windows.\n\n' +
                report['boundary'] + '. No model, publication or actual server restore was run.\n', encoding='utf-8')
            replacements.append(('BACKUP-CATALOG.md', markdown))
            commit_swaps(data, stage, replacements, preconditions)
            if sha(report['archive']) != proof['sha256']:
                raise SyncError('Canonical recovery archive changed; no cleanup allowed')
            removed = cleanup_mir(data, stage)
            write_json(stage / 'result.json', dict(report, status='complete', removedCaches=removed))
            print('SYNC ALL COMPLETE:', len(catalog['repositories']), 'repositories,', len(projects), 'folders; all payloads checked')
            print('MIR cleanup complete:', len(removed), 'old/cache entries removed')
            print('Report:', data / 'BACKUP-CATALOG.json')
        except BaseException as error:
            write_json(stage / 'failure.json', dict(status='failed', error=str(error)))
            print('SYNC ALL FAILED. Inspect transaction status; unfinished replacements are recoverable. Details:', stage / 'failure.json', file=sys.stderr)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True)
    parser.add_argument('--root', required=True)
    parser.add_argument('--rclone', default='rclone')
    parser.add_argument('--ssh', default='ssh')
    parser.add_argument('--only', default='')
    parser.add_argument('--what-if', action='store_true')
    parser.add_argument('--snapshot', help='Existing canonical archive with adjacent .sha256; no R2 download')
    parser.add_argument('--catalog', help='Offline test catalog with localPath repositories; requires --snapshot')
    args = parser.parse_args()
    if args.catalog and not args.snapshot:
        parser.error('--catalog requires --snapshot')
    try:
        execute(args)
    except Exception as error:
        print('ERROR:', str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
