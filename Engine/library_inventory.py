"""Read-only MAIN VPS catalog, sent to python3 over SSH stdin by SYNC ALL.

No credentials, temporary files, network probes or writes on either server.
"""
import json
from pathlib import Path
import re
import subprocess
import sys


def git(path, *args, optional=False):
    result = subprocess.run(['git', '-c', 'safe.directory=' + str(path), '-C', str(path), *args],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        if optional:
            return ''
        raise ValueError('Cannot inspect Git: ' + path.name)
    return result.stdout.decode('utf-8').strip()


def catalog(settings):
    root = Path(settings['forgejo']['root'])
    if not root.is_absolute() or not root.is_dir():
        raise ValueError('Forgejo repository root is unavailable')
    active = {item['repository']: Path(item['path']) for item in settings['sources']
              if item['from'] == 'git' and item.get('path')}
    for parent_name in settings.get('checkoutRoots', []):
        parent = Path(parent_name)
        if not parent.is_absolute() or not parent.is_dir():
            raise ValueError('Checkout discovery root is unavailable')
        for path in sorted(parent.iterdir()):
            if path.is_symlink() or not (path / '.git').is_dir():
                continue
            remote = git(path, 'config', '--get', 'remote.origin.url', optional=True)
            for owner in settings['forgejo']['owners']:
                match = re.search(r'(?:/|:)' + re.escape(owner) + r'/([a-zA-Z0-9_.-]+\.git)$', remote)
                if match:
                    active.setdefault(owner + '/' + match[1], path)
    repositories = []
    for owner in settings['forgejo']['owners']:
        if not re.fullmatch(r'[a-zA-Z0-9_-]+', owner):
            raise ValueError('Unsafe Forgejo owner')
        directory = root / owner
        if not directory.is_dir() or directory.is_symlink():
            raise ValueError('Forgejo owner directory is unavailable')
        for path in sorted(directory.glob('*.git')):
            if path.is_symlink() or not path.is_dir() or not re.fullmatch(r'[a-zA-Z0-9_.-]+\.git', path.name):
                raise ValueError('Unsafe Forgejo repository entry')
            repository = owner + '/' + path.name
            refs = git(path, 'for-each-ref', '--format=%(objectname) %(refname)')
            head_ref = git(path, 'symbolic-ref', 'HEAD')
            head = git(path, 'rev-parse', '--verify', 'HEAD', optional=True)
            item = dict(repository=repository, head=head, headRef=head_ref,
                        refs=[dict(oid=line.split(' ', 1)[0], ref=line.split(' ', 1)[1])
                              for line in refs.splitlines()])
            if repository in active:
                checkout = active[repository]
                branch = git(checkout, 'branch', '--show-current')
                current = git(checkout, 'rev-parse', 'HEAD')
                if not branch or git(path, 'rev-parse', 'refs/heads/' + branch) != current:
                    raise ValueError('Active checkout is detached or not pushed: ' + repository)
                item.update(activePath=str(checkout), activeBranch=branch, activeHead=current)
            repositories.append(item)
    if not repositories:
        raise ValueError('Empty Forgejo inventory')
    found = {item['repository'] for item in repositories}
    for item in settings['sources']:
        if item['from'] == 'git' and item['repository'] not in found:
            raise ValueError('Configured repository missing from Forgejo: ' + item['repository'])
    return dict(version=2, repositories=repositories)


if __name__ == '__main__':
    try:
        print(json.dumps(catalog(json.loads(sys.argv[1])), ensure_ascii=True))
    except Exception as error:
        print('LIBRARY_INVENTORY_FAILED: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
