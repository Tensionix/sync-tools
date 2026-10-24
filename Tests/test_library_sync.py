"""Adversarial local-only SYNC ALL fixtures: real Git, tar, hashes and renames."""
import argparse
from copy import deepcopy
import hashlib
import importlib.util
import io
import json
import os
import shlex
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

APP = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(APP / 'Engine'))
import library_sync as sync
import library_inventory as inventory


def put(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(value.encode() if isinstance(value, str) else value)


def tar_bytes(entries):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w:gz') as archive:
        for name, value in entries:
            member = tarfile.TarInfo(name)
            member.mode, member.uid, member.gid = 0o644, 0, 0
            if isinstance(value, tarfile.TarInfo):
                value.name = name
                archive.addfile(value)
            else:
                member.size = len(value)
                archive.addfile(member, io.BytesIO(value))
    return output.getvalue()


class LibraryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='audion-sync-fixture-')
        self.root = Path(self.temp.name)
        self.data = self.root / 'DATA with spaces'
        self.data.mkdir()
        self.repo = self.root / 'origin.git'
        self.work = self.root / 'work'
        subprocess.run(['git', 'init', '--quiet', '-b', 'main', self.work], check=True)
        sync.git(self.work, 'config', 'user.name', 'Fixture')
        sync.git(self.work, 'config', 'user.email', 'fixture@example.invalid')
        put(self.work / 'code.txt', 'source\n')
        put(self.work / 'unchanged.txt', 'stable\n')
        put(self.work / '.gitignore', 'secrets/\n')
        sync.git(self.work, 'add', '.')
        sync.git(self.work, 'commit', '--quiet', '-m', 'source')
        sync.run(['git', 'clone', '--quiet', '--bare', self.work, self.repo])
        self.head = sync.text(sync.git(self.repo, 'rev-parse', 'HEAD'))
        self.catalog = dict(version=2, repositories=[dict(repository='owner/project.git',
            head=self.head, headRef='refs/heads/main', localPath=str(self.repo),
            refs=[dict(oid=self.head, ref='refs/heads/main')])])
        self.catalog_path = self.root / 'catalog.json'
        sync.write_json(self.catalog_path, self.catalog)
        self.plan = dict(version=2, mode='mir', protectedLocal={}, server='main-fixture', bucket='unused:bucket', checkoutRoots=[],
            forgejo=dict(root=str(self.root), owners=['owner'], url='ssh://unused', identity='Tunnel/key', knownHosts='Tunnel/known'),
            coverage=[dict(part='server-config.tar.gz', role='main', prefix='/')],
            sources=[dict(folder='Project', repository='owner/project.git', **{'from': 'git'},
                          overlays=[dict(part='project.tar.gz', prefixes=['data'], strip=0)])])
        sync.write_json(self.data / 'config/mirror.json', self.plan)
        self.snapshot = self.root / 'snapshot.tar.gz'
        self.make_snapshot()

    def tearDown(self):
        # Git objects can be read-only on Windows; only remove our resolved lab.
        def retry(function, path, error):
            os.chmod(path, 0o700)
            function(path)
        resolved = self.root.resolve()
        if resolved.parent == Path(tempfile.gettempdir()).resolve() and resolved.name.startswith('audion-sync-fixture-'):
            shutil.rmtree(resolved, onerror=retry)
        self.temp.cleanup()

    def make_snapshot(self, *, bad_manifest=False, missing=False, bad_coverage=False, extra=None):
        body = b'installed unit\n'
        record = dict(host='fixture-host', path='/etc/systemd/system/example.service',
                      type='file', mode=0o644, uid=0, gid=0,
                      sha256=hashlib.sha256(body if not bad_coverage else b'wrong').hexdigest())
        installed = tar_bytes([('/etc/systemd/system/example.service', body)])
        forgejo = tar_bytes([('repos/owner/project.git/refs/heads/main', (self.head + '\n').encode())])
        operational = dict(format='operational-inventory/1', records=[record], errors=[],
                           git_heads=[dict(repository='owner/project.git', branch='main', head=self.head)])
        entries = [('manifest.txt', b'host: fixture-host\n'),
                   ('payload/server-config.tar.gz', installed),
                   ('payload/git-forgejo.tar.gz', forgejo),
                   ('payload/operational-inventory.json', json.dumps(operational).encode()),
                   ('payload/project.tar.gz', tar_bytes([('data/day.json', b'published\n')])),
                   ('payload/new-future-state.tar.gz', tar_bytes([('private/state', b'new payload')]))]
        if missing:
            entries = [row for row in entries if row[0] != 'payload/project.tar.gz']
        manifest = '\n'.join(hashlib.sha256(value).hexdigest() + '  ./' + name for name, value in entries)
        if bad_manifest:
            manifest = manifest.replace(hashlib.sha256(installed).hexdigest(), '0' * 64)
        entries += [('manifest.sha256', (manifest + '\n').encode())]
        if extra:
            entries += extra
        put(self.snapshot, tar_bytes([('audion-main-server-recovery/' + name, value) for name, value in entries]))
        put(Path(str(self.snapshot) + '.sha256'), sync.sha(self.snapshot) + '  snapshot.tar.gz\n')

    def args(self, **kwargs):
        return argparse.Namespace(app=str(APP), root=str(self.data), catalog=str(self.catalog_path),
            snapshot=str(self.snapshot), rclone='NEVER-RUN-RCLONE', ssh='NEVER-RUN-SSH',
            only=kwargs.get('only', ''), what_if=kwargs.get('what_if', False))

    def clone_old(self):
        target = self.data / 'Project'
        sync.run(['git', 'clone', '--quiet', self.repo, target])
        return target

    def update_remote(self, name='code.txt', value='upstream\n'):
        put(self.work / name, value)
        sync.git(self.work, 'add', '.')
        sync.git(self.work, 'commit', '--quiet', '-m', 'upstream')
        sync.git(self.work, 'push', str(self.repo), 'main')
        self.catalog['repositories'][0]['head'] = sync.text(sync.git(self.repo, 'rev-parse', 'HEAD'))
        self.catalog['repositories'][0]['refs'][0]['oid'] = self.catalog['repositories'][0]['head']
        sync.write_json(self.catalog_path, self.catalog)

    def test_complete_real_git_and_every_payload(self):
        put(self.data / 'Snapshots/old.tar.gz', 'keep old')
        sync.execute(self.args())
        report = sync.read_json(self.data / 'BACKUP-CATALOG.json')
        self.assertEqual(len(report['snapshot']['payloads']), 5)
        self.assertEqual((self.data / 'Project/data/day.json').read_bytes(), b'published\n')
        self.assertEqual(sync.refs(self.data / 'Forgejo Mirror/project.git'), sync.refs(self.repo))
        self.assertEqual((self.data / 'Snapshots/old.tar.gz').read_text(), 'keep old')
        self.assertTrue(Path(report['archive']).is_file())
        sync.git(self.data / 'Project', 'fsck', '--full')

    def test_new_repository_and_branch_tag_discovery(self):
        other = self.root / 'owner/new.git'
        other.parent.mkdir()
        sync.run(['git', 'clone', '--quiet', '--bare', self.work, other])
        sync.git(other, 'tag', 'v1')
        sync.git(other, 'branch', 'other')
        item = deepcopy(self.catalog['repositories'][0])
        item.update(repository='owner/new.git', localPath=str(other),
                    refs=[dict(oid=line.split()[0], ref=line.split()[1]) for line in sync.refs(other)])
        self.catalog['repositories'].append(item)
        sync.write_json(self.catalog_path, self.catalog)
        sync.execute(self.args())
        self.assertTrue((self.data / 'Repositories/owner/new/code.txt').is_file())
        self.assertEqual(sync.refs(self.data / 'Forgejo Mirror/new.git'), sync.refs(other))

    def test_repeat_mir_does_not_accumulate_original_folders(self):
        sync.execute(self.args())
        first = sorted((self.data / 'Recovery/sync-all').glob('sync-all-20*'))[0]
        sync.execute(self.args())
        self.assertFalse(first.exists())
        self.assertFalse(list((self.data / 'Recovery/sync-all').glob('sync-all-*/before')))
        self.assertEqual((self.data / 'Project/data/day.json').read_bytes(), b'published\n')

    def test_mir_removes_local_edits_extras_but_preserves_explicit_secrets(self):
        old = self.clone_old()
        put(old / 'code.txt', 'local edit\n')
        put(old / 'secrets/private.txt', b'PRIVATE-LOCAL-FIXTURE')
        put(old / '.local-hidden', b'hidden')
        (old / 'empty').mkdir()
        (old / 'unchanged.txt').unlink()
        self.plan['protectedLocal'] = {'Project': ['secrets']}
        sync.write_json(self.data / 'config/mirror.json', self.plan)
        sync.execute(self.args())
        self.assertEqual((old / 'code.txt').read_bytes(), b'source\n')
        self.assertEqual((old / 'secrets/private.txt').read_bytes(), b'PRIVATE-LOCAL-FIXTURE')
        self.assertFalse((old / 'empty').exists())
        self.assertFalse((old / '.local-hidden').exists())
        self.assertTrue((old / 'unchanged.txt').is_file())

    def test_mir_installs_upstream_and_discards_unrelated_local_edit(self):
        old = self.clone_old()
        put(old / 'unchanged.txt', 'my local edit\n')
        self.update_remote()
        sync.execute(self.args())
        self.assertEqual((old / 'code.txt').read_bytes(), b'upstream\n')
        self.assertEqual((old / 'unchanged.txt').read_bytes(), b'stable\n')

    def test_mir_server_version_wins_on_local_conflict(self):
        old = self.clone_old()
        put(old / 'code.txt', 'my local change\n')
        self.update_remote()
        sync.execute(self.args())
        self.assertEqual((old / 'code.txt').read_bytes(), b'upstream\n')
        self.assertFalse(list((self.data / 'Recovery/sync-all').glob('sync-all-*/before')))

    def test_mir_replaces_local_only_commit_with_server_branch(self):
        old = self.clone_old()
        sync.git(old, 'config', 'user.name', 'Fixture')
        sync.git(old, 'config', 'user.email', 'fixture@example.invalid')
        put(old / 'local.txt', 'local commit')
        sync.git(old, 'add', '.')
        sync.git(old, 'commit', '--quiet', '-m', 'unpublished')
        sync.execute(self.args())
        self.assertEqual(sync.text(sync.git(old, 'rev-parse', 'HEAD')), self.head)
        self.assertFalse((old / 'local.txt').exists())

    def test_missing_payload_and_bad_checksums_never_replace(self):
        old = self.clone_old()
        before = sync.tree_state(old)
        for options in [dict(missing=True), dict(bad_manifest=True), dict(bad_coverage=True)]:
            with self.subTest(options=options):
                self.make_snapshot(**options)
                with self.assertRaises((sync.SyncError, tarfile.TarError)):
                    sync.execute(self.args())
                self.assertEqual(sync.tree_state(old), before)
        self.make_snapshot()
        put(Path(str(self.snapshot) + '.sha256'), '0' * 64)
        with self.assertRaisesRegex(sync.SyncError, 'checksum mismatch'):
            sync.execute(self.args())
        self.assertEqual(sync.tree_state(old), before)

    def test_truncated_archive_with_matching_outer_sum_rejected(self):
        put(self.snapshot, self.snapshot.read_bytes()[:400])
        put(Path(str(self.snapshot) + '.sha256'), sync.sha(self.snapshot))
        with self.assertRaises((EOFError, tarfile.TarError, sync.SyncError)):
            sync.execute(self.args())
        self.assertFalse((self.data / 'Project').exists())

    def test_unmanifested_and_traversal_and_case_collision_rejected(self):
        for extra in [[('extra.txt', b'unlisted')], [('../escape', b'escape')], [('MANIFEST.TXT', b'collision')]]:
            with self.subTest(extra=extra):
                self.make_snapshot(extra=extra)
                with self.assertRaises(sync.SyncError):
                    sync.execute(self.args())
        self.assertFalse((self.root / 'escape').exists())

    def test_outer_symlink_refused(self):
        link = tarfile.TarInfo('link')
        link.type, link.linkname = tarfile.SYMTYPE, '../../outside'
        self.make_snapshot(extra=[('link', link)])
        with self.assertRaisesRegex(sync.SyncError, 'links/special'):
            sync.execute(self.args())

    def test_mir_replaces_local_publication_with_verified_snapshot(self):
        old = self.clone_old()
        put(old / 'data/day.json', 'different local copy')
        sync.execute(self.args())
        self.assertEqual((old / 'data/day.json').read_bytes(), b'published\n')

    def test_mir_removes_obsolete_repositories_and_mirror_notes(self):
        put(self.data / 'Forgejo Mirror/removed.git/HEAD', 'obsolete repository')
        put(self.data / 'Forgejo Mirror/my-note.txt', 'obsolete note')
        put(self.data / 'Repositories/owner/removed/old.txt', 'obsolete auto checkout')
        sync.execute(self.args())
        self.assertFalse((self.data / 'Forgejo Mirror/removed.git').exists())
        self.assertFalse((self.data / 'Forgejo Mirror/my-note.txt').exists())
        self.assertFalse((self.data / 'Repositories/owner/removed').exists())

    def test_dry_run_zero_data_writes(self):
        before = sync.tree_state(self.data)
        sync.execute(self.args(what_if=True))
        self.assertEqual(sync.tree_state(self.data), before)

    def test_only_unknown_refused_and_only_project_does_not_replace_mirrors(self):
        with self.assertRaisesRegex(sync.SyncError, 'Unknown -Only'):
            sync.execute(self.args(only='Typo'))
        self.assertFalse((self.data / 'Project').exists())
        put(self.data / 'Forgejo Mirror/local.txt', 'mirror not selected')
        old = sync.tree_state(self.data / 'Forgejo Mirror')
        sync.execute(self.args(only='Project'))
        self.assertEqual(sync.tree_state(self.data / 'Forgejo Mirror'), old)
        self.assertTrue((self.data / 'Project/code.txt').is_file())

    def test_plan_rejects_protected_and_overlapping_folders(self):
        for folder in ['../outside', 'Tunnel', 'config', 'Snapshots', 'Recovery', 'Project/sub']:
            plan = deepcopy(self.plan)
            plan['sources'].append(dict(folder=folder, **{'from': 'payload'}, part='project.tar.gz'))
            sync.write_json(self.data / 'config/mirror.json', plan)
            with self.assertRaises(sync.SyncError):
                sync.execute(self.args())

    def test_nonwindows_archive_names_refused(self):
        for name in ['C:/outside', '/absolute', 'a\\b', 'nul.txt', 'x/COM1', 'x:stream', 'trailing.']:
            with self.subTest(name=name), self.assertRaises(sync.SyncError):
                sync.relative(name)

    def test_real_local_junction_refused(self):
        old = self.clone_old()
        outside = self.root / 'outside'
        outside.mkdir()
        put(outside / 'do-not-touch.txt', 'outside')
        link = old / 'junction'
        if os.name == 'nt':
            subprocess.run(['cmd', '/c', 'mklink', '/J', str(link), str(outside)], check=True, capture_output=True)
        else:
            link.symlink_to(outside, target_is_directory=True)
        try:
            with self.assertRaisesRegex(sync.SyncError, 'junction|Reparse'):
                sync.execute(self.args())
            self.assertEqual((outside / 'do-not-touch.txt').read_text(), 'outside')
        finally:
            if os.name == 'nt':
                link.rmdir()
            else:
                link.unlink()

    def test_lock_refuses_second_writer(self):
        with sync.data_lock(self.data):
            with self.assertRaisesRegex(sync.SyncError, 'already using'):
                with sync.data_lock(self.data):
                    self.fail('second writer entered')

    def transaction_fixture(self):
        stage = self.data / 'Recovery/sync-all/sync-all-fixture'
        stage.mkdir(parents=True)
        put(self.data / 'A/a', 'old A')
        put(self.data / 'B/b', 'old B')
        put(stage / 'incoming/A/a', 'new A')
        put(stage / 'incoming/B/b', 'new B')
        return stage, [('A', stage / 'incoming/A'), ('B', stage / 'incoming/B')]

    def test_failed_second_swap_rolls_back_all_bytes(self):
        stage, replacements = self.transaction_fixture()
        original = sync.tree_state(self.data / 'A'), sync.tree_state(self.data / 'B')
        replace = os.replace
        def fail(source, destination):
            if Path(source) == stage / 'incoming/B':
                raise OSError('injected locked destination')
            return replace(source, destination)
        with patch.object(sync.os, 'replace', side_effect=fail):
            with self.assertRaises(OSError):
                sync.commit_swaps(self.data, stage, replacements)
        self.assertEqual((sync.tree_state(self.data / 'A'), sync.tree_state(self.data / 'B')), original)
        self.assertEqual(sync.read_json(stage / 'transaction.json')['status'], 'rolled-back')

    def test_power_loss_between_rename_and_journal_recovers(self):
        stage, replacements = self.transaction_fixture()
        old = sync.tree_state(self.data / 'A')
        new = sync.tree_state(stage / 'incoming/A')
        (stage / 'before').mkdir()
        os.replace(self.data / 'A', stage / 'before/A')
        os.replace(stage / 'incoming/A', self.data / 'A')
        sync.write_json(stage / 'transaction.json', dict(status='prepared', replacements=[dict(
            name='A', incoming='incoming/A', old=old, new=new, installed=False, movedOld=False, intent='install')]))
        sync.recover_pending(self.data)
        self.assertEqual(sync.tree_state(self.data / 'A'), old)
        self.assertEqual(sync.tree_state(stage / 'incoming/A'), new)

    def test_recovery_does_not_overwrite_edits_after_interruption(self):
        stage, replacements = self.transaction_fixture()
        old, new = sync.tree_state(self.data / 'A'), sync.tree_state(stage / 'incoming/A')
        (stage / 'before').mkdir()
        os.replace(self.data / 'A', stage / 'before/A')
        os.replace(stage / 'incoming/A', self.data / 'A')
        put(self.data / 'A/a', 'edited after crash')
        sync.write_json(stage / 'transaction.json', dict(status='prepared', replacements=[dict(
            name='A', incoming='incoming/A', old=old, new=new, intent='install')]))
        with self.assertRaisesRegex(sync.SyncError, 'manual recovery'):
            sync.recover_pending(self.data)
        self.assertEqual((self.data / 'A/a').read_text(), 'edited after crash')
        self.assertEqual(sync.tree_state(stage / 'before/A'), old)

    def test_edit_during_staging_detected_before_any_swap(self):
        stage, replacements = self.transaction_fixture()
        before = {'A': sync.tree_state(self.data / 'A')}
        put(self.data / 'A/a', 'edited while staging')
        with self.assertRaisesRegex(sync.SyncError, 'changed during staging'):
            sync.commit_swaps(self.data, stage, replacements, before)
        self.assertEqual((self.data / 'A/a').read_text(), 'edited while staging')
        self.assertEqual((self.data / 'B/b').read_text(), 'old B')

    def test_live_inventory_new_bare_repo_detected_without_fixed_list(self):
        repo_root = self.root / 'forgejo/owner'
        repo_root.mkdir(parents=True)
        sync.run(['git', 'clone', '--quiet', '--bare', self.work, repo_root / 'new.git'])
        plan = deepcopy(self.plan)
        plan['forgejo']['root'] = str(repo_root.parent)
        plan['sources'] = []
        result = inventory.catalog(plan)
        self.assertEqual(result['repositories'][0]['repository'], 'owner/new.git')

    def test_git_inventory_mismatch_stops_before_replacement(self):
        self.catalog['repositories'][0]['refs'].append(dict(oid=self.head, ref='refs/heads/missing'))
        sync.write_json(self.catalog_path, self.catalog)
        with self.assertRaisesRegex(sync.SyncError, 'changed during clone'):
            sync.execute(self.args())
        self.assertFalse((self.data / 'Forgejo Mirror').exists())

    def test_wrapper_uses_own_engine_and_restores_environment(self):
        wrapper = (APP / 'Engine/Scripts/Sync-AudionBackup.ps1').read_text(encoding='utf-8-sig')
        self.assertIn('library_sync.py', wrapper)
        self.assertIn('Get-AbkRcloneEnvironment', wrapper)
        self.assertIn('finally', wrapper)
        self.assertNotIn('/MIR', wrapper)

    def test_gzip_footer_truncation_with_matching_sha_is_rejected(self):
        put(self.snapshot, self.snapshot.read_bytes()[:-7])
        put(Path(str(self.snapshot) + '.sha256'), sync.sha(self.snapshot))
        with self.assertRaises((EOFError, tarfile.TarError, sync.SyncError)):
            sync.execute(self.args())
        self.assertFalse((self.data / 'Project').exists())

    def test_empty_new_repository_and_repeat_mir(self):
        empty = self.root / 'empty.git'
        sync.run(['git', 'init', '--bare', '--quiet', '-b', 'main', empty])
        self.catalog['repositories'].append(dict(repository='owner/empty.git', localPath=str(empty),
                                                head='', headRef='refs/heads/main', refs=[]))
        sync.write_json(self.catalog_path, self.catalog)
        sync.execute(self.args())
        target = self.data / 'Repositories/owner/empty'
        self.assertTrue((target / '.git').is_dir())
        put(target / 'local.txt', 'local extra')
        sync.execute(self.args())
        self.assertFalse((target / 'local.txt').exists())

    def test_the_plan_lives_in_data_and_the_template_holds_no_value(self):
        # The program carries a template: every value of it is a <...>, or a word of the format itself.
        template = sync.read_json(APP / 'config/mirror.sample.json')
        words = {'mir', 'main', 'second', 'git', 'payload', '/'}
        def leaves(value, key=''):
            if key.startswith('_'):
                return []
            if isinstance(value, dict):
                return [leaf for name, item in value.items() for leaf in leaves(item, name)]
            if isinstance(value, list):
                return [leaf for item in value for leaf in leaves(item)]
            return [value] if isinstance(value, str) else []
        self.assertEqual([leaf for leaf in leaves(template) if '<' not in leaf and leaf not in words], [])
        # No plan, an old version 1 plan, the template copied as it is: refused, and nothing in DATA is written.
        with self.assertRaisesRegex(sync.SyncError, 'No SYNC ALL plan'):
            sync.load_plan(self.root / 'no-plan.json')
        copied = self.root / 'copied-template.json'
        sync.write_json(copied, template)
        with self.assertRaisesRegex(sync.SyncError, 'values of the template'):
            sync.load_plan(copied)
        plan = self.data / 'config/mirror.json'
        sync.write_json(plan, dict(sources=[dict(folder='Project', **{'from': 'server'}, path='/srv/project')]))
        before = sync.tree_state(self.data)
        with self.assertRaisesRegex(sync.SyncError, 'version 1'):
            sync.execute(self.args())
        self.assertEqual(sync.tree_state(self.data), before)

    def test_server_catalog_change_during_run_refuses_install(self):
        changed = deepcopy(self.catalog)
        changed['repositories'][0]['head'] = '0' * 40
        with patch.object(sync.Transport, 'catalog', side_effect=[self.catalog, changed]):
            with self.assertRaisesRegex(sync.SyncError, 'inventory changed'):
                sync.execute(self.args())
        self.assertFalse((self.data / 'Project').exists())

    def test_wrapper_failure_returns_nonzero_without_touching_data(self):
        shell = APP / 'App/AudionPs.exe'
        before = sync.tree_state(self.data)
        if os.name != 'nt' or not shell.exists():
            self.skipTest('Bundled Windows PowerShell is unavailable')
        bad = self.root / 'missing DATA'
        result = subprocess.run([shell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                                 APP / 'Engine/Scripts/Sync-AudionBackup.ps1', '-Root', bad, '-NoPause'],
                                capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(bad.exists())
        self.assertEqual(sync.tree_state(self.data), before)

    def test_openssh_known_hosts_preserves_its_second_level_quotes(self):
        put(self.data / 'Tunnel/key', 'fixture, never used for connection')
        put(self.data / 'Tunnel/known', 'fixture host trust')
        transport = sync.Transport(APP, self.data, self.plan, 'unused', 'ssh')
        options = shlex.split(transport.ssh_command)
        expected = 'UserKnownHostsFile="' + (self.data / 'Tunnel/known').as_posix() + '"'
        self.assertIn(expected, options)
        self.assertIn('StrictHostKeyChecking=yes', options)
        self.assertIn('UpdateHostKeys=no', options)

    def test_interrupted_download_keeps_previous_snapshot_and_sources(self):
        old = self.clone_old()
        put(self.data / 'Snapshots/previous.tar.gz', 'previous canonical archive')
        before = sync.tree_state(old)
        args = self.args()
        args.snapshot = ''
        def interrupted(instance, stage):
            put(stage / 'download.partial', b'incomplete archive')
            raise sync.SyncError('download interrupted')
        with patch.object(sync.Transport, 'latest_snapshot', interrupted):
            with self.assertRaisesRegex(sync.SyncError, 'download interrupted'):
                sync.execute(args)
        self.assertEqual(sync.tree_state(old), before)
        self.assertEqual((self.data / 'Snapshots/previous.tar.gz').read_text(), 'previous canonical archive')

    def test_success_mir_cleans_old_failed_generations(self):
        old = self.data / 'Recovery/sync-all/sync-all-20000101T000000Z-deadbeef'
        put(old / 'before/Project/obsolete.txt', 'obsolete old source')
        sync.write_json(old / 'failure.json', {'status': 'failed'})
        sync.execute(self.args())
        self.assertFalse(old.exists())
        self.assertFalse(list((self.data / 'Recovery/sync-all').glob('sync-all-*/before')))
        self.assertEqual(sync.read_json(self.data / 'BACKUP-CATALOG.json')['mode'], 'mir')

    def test_mir_replaces_legacy_non_git_folder(self):
        old = self.data / 'Project'
        put(old / 'code.txt', 'old unversioned source')
        put(old / 'my-notes.txt', 'old local extra')
        sync.execute(self.args())
        self.assertEqual((old / 'code.txt').read_bytes(), b'source\n')
        self.assertFalse((old / 'my-notes.txt').exists())
        self.assertTrue((old / '.git').is_dir())

    def test_failed_validation_does_not_clean_previous_generations(self):
        old = self.data / 'Recovery/sync-all/sync-all-20000101T000000Z-deadbeef'
        put(old / 'before/Project/old.txt', 'still recoverable')
        sync.write_json(old / 'transaction.json', {'status': 'complete'})
        self.make_snapshot(bad_manifest=True)
        with self.assertRaises(sync.SyncError):
            sync.execute(self.args())
        self.assertEqual((old / 'before/Project/old.txt').read_text(), 'still recoverable')

    def test_mir_cleanup_preserves_connections_snapshots_and_unowned_runtime(self):
        sentinels = ['Tunnel/key', 'config/rclone/rclone.conf', 'Snapshots/old.tar.gz',
                     '._runtime/tunnel-refresh-20261023/key',
                     'Recovery/sync-all/sync-all-personal-notes/note.txt']
        for name in sentinels:
            put(self.data / name, 'protected fixture ' + name)
        sync.execute(self.args())
        for name in sentinels:
            self.assertEqual((self.data / name).read_text(), 'protected fixture ' + name)

    def test_mir_cleanup_refuses_pending_and_unrecognized_cache(self):
        stage = self.data / 'Recovery/sync-all/sync-all-20990101T000000Z-deadbeef'
        put(stage / 'before/Project/original.txt', 'temporary original')
        sync.write_json(stage / 'transaction.json', {'status': 'prepared'})
        with self.assertRaisesRegex(sync.SyncError, 'successfully verified'):
            sync.cleanup_mir(self.data, stage)
        sync.write_json(stage / 'transaction.json', {'status': 'complete'})
        previous = self.data / 'Recovery/sync-all/sync-all-20000101T000000Z-cafebabe'
        put(previous / 'note.txt', 'not proven to belong to this engine')
        with self.assertRaisesRegex(sync.SyncError, 'Unrecognized'):
            sync.cleanup_mir(self.data, stage)
        sync.write_json(previous / 'transaction.json', {'status': 'installing'})
        with self.assertRaisesRegex(sync.SyncError, 'Unfinished transaction'):
            sync.cleanup_mir(self.data, stage)
        self.assertTrue((stage / 'before/Project/original.txt').is_file())

    def test_mir_cleanup_refuses_nested_junction_without_following_it(self):
        if os.name != 'nt':
            self.skipTest('Windows junction fixture')
        outside = self.root / 'outside'
        put(outside / 'keep.txt', 'not cleanup material')
        target = self.root / 'owned-cache'
        target.mkdir()
        junction = target / 'escape'
        result = subprocess.run(['cmd.exe', '/c', 'mklink', '/J', str(junction), str(outside)],
                                capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        try:
            with self.assertRaisesRegex(sync.SyncError, 'nested reparse'):
                sync.delete_owned(target, self.root)
            self.assertEqual((outside / 'keep.txt').read_text(), 'not cleanup material')
            with self.assertRaisesRegex(sync.SyncError, 'Unsafe cleanup target'):
                sync.delete_owned(self.root, self.root)
        finally:
            os.rmdir(junction)

    def test_verified_cache_reuses_objects_but_still_checks_catalog(self):
        sync.execute(self.args())
        self.repo.rename(self.root / 'temporarily-unavailable.git')
        # Offline catalog freezes the expected refs as a server inventory would.
        sync.execute(self.args())
        self.assertEqual(sync.refs(self.data / 'Forgejo Mirror/project.git'),
                         [self.head + ' refs/heads/main'])
        self.assertEqual(sync.text(sync.git(self.data / 'Forgejo Mirror/project.git', 'remote', 'get-url', 'origin')),
                         str(self.repo))

    def test_invalid_cache_is_refetched_and_removed_after_success(self):
        sync.execute(self.args())
        old = self.data / 'Forgejo Mirror/project.git'
        put(old / 'HEAD', 'invalid old HEAD')
        sync.execute(self.args())
        self.assertEqual(sync.text(sync.git(old, 'rev-parse', 'HEAD')), self.head)
        self.assertFalse(list((self.data / 'Recovery/sync-all').glob('sync-all-*/before')))

    def test_unreadable_subtree_is_not_silently_omitted(self):
        def broken_walk(root, **kwargs):
            kwargs['onerror'](PermissionError('fixture unreadable directory'))
            return iter([])
        with patch.object(sync.os, 'walk', broken_walk):
            with self.assertRaises(PermissionError):
                sync.files(self.data)

    def test_empty_only_is_not_promoted_to_sync_all(self):
        before = sync.tree_state(self.data)
        with self.assertRaisesRegex(sync.SyncError, 'Empty -Only'):
            sync.execute(self.args(only=' , '))
        self.assertEqual(sync.tree_state(self.data), before)

    def test_incomplete_checkout_is_rejected_even_with_healthy_git_objects(self):
        old = self.clone_old()
        (old / 'code.txt').unlink()
        with self.assertRaisesRegex(sync.SyncError, 'missing a source'):
            sync.verify_checkout(old, self.head)

    def test_git_status_index_refresh_is_not_a_data_conflict(self):
        old = self.clone_old()
        before = sync.stable_state(old)
        code = old / 'code.txt'
        info = code.stat()
        os.utime(code, ns=(info.st_atime_ns, info.st_mtime_ns + 2000000000))
        sync.run(['git', '-C', old, 'update-index', '--refresh'])
        physical = sync.tree_state(old)
        self.assertEqual(sync.stable_state(old), before)
        stage = self.data / 'Recovery/sync-all/sync-all-index-refresh'
        stage.mkdir(parents=True)
        sync.run(['git', '-c', 'core.autocrlf=false', 'clone', '--quiet', self.repo, stage / 'incoming'])
        sync.commit_swaps(self.data, stage, [('Project', stage / 'incoming')], {'Project': before})
        self.assertEqual(sync.tree_state(stage / 'before/Project'), physical)

    def test_staged_index_content_change_still_stops_replacement(self):
        old = self.clone_old()
        before = sync.stable_state(old)
        put(old / 'code.txt', 'staged edit\n')
        sync.git(old, 'add', 'code.txt')
        self.assertNotEqual(sync.stable_state(old), before)

    def test_interrupted_sync_recovers_after_runtime_is_deleted(self):
        stage, replacements = self.transaction_fixture()
        old = sync.tree_state(self.data / 'A')
        new = sync.tree_state(stage / 'incoming/A')
        (stage / 'before').mkdir()
        os.replace(self.data / 'A', stage / 'before/A')
        os.replace(stage / 'incoming/A', self.data / 'A')
        sync.write_json(stage / 'transaction.json', dict(status='prepared', replacements=[dict(
            name='A', incoming='incoming/A', old=old, new=new, intent='install')]))
        put(self.data / '._runtime/rclone-cache/disposable', 'cache')
        shutil.rmtree(self.data / '._runtime')
        with sync.data_lock(self.data):
            sync.recover_pending(self.data)
        self.assertEqual(sync.tree_state(self.data / 'A'), old)
        self.assertEqual(sync.read_json(stage / 'transaction.json')['status'], 'rolled-back')
        self.assertTrue((self.data / 'config/sync-all.lock').is_file())

    def test_old_runtime_transaction_is_migrated_whole_before_recovery(self):
        old_stage = self.data / '._runtime/sync-all-20000101T000000Z-1234abcd'
        target = self.data / 'Recovery/sync-all' / old_stage.name
        put(self.data / 'A/original', 'old original')
        put(old_stage / 'incoming/A/new', 'new incoming')
        old, new = sync.tree_state(self.data / 'A'), sync.tree_state(old_stage / 'incoming/A')
        (old_stage / 'before').mkdir()
        os.replace(self.data / 'A', old_stage / 'before/A')
        os.replace(old_stage / 'incoming/A', self.data / 'A')
        sync.write_json(old_stage / 'transaction.json', dict(status='prepared', replacements=[dict(
            name='A', incoming='incoming/A', old=old, new=new, intent='install')]))
        with sync.data_lock(self.data):
            sync.recover_pending(self.data)
        self.assertFalse(old_stage.exists())
        self.assertEqual(sync.tree_state(self.data / 'A'), old)
        self.assertEqual(sync.read_json(target / 'transaction.json')['status'], 'rolled-back')


if __name__ == '__main__':
    unittest.main(verbosity=2)
