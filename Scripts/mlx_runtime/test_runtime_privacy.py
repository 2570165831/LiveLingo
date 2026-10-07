"""Synthetic worker/checkpoint regressions; backend imports are forbidden."""
import ast
import contextlib
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

from test_checkpoint_lifecycle import WorkerSession, checkpoint_path, note_command
from review_diagnostics import failure_line, generation_detail, parse_review_input
from review_diagnostics import ReviewFailure, safe_error_message

ROOT = Path(__file__).resolve().parent
CANARY = 'SYNTHETIC_PRIVATE_SENTENCE'
BOOT = r'''
import hashlib, sys, time, types
from pathlib import Path
class NoBackends:
    def find_spec(self, fullname, path=None, target=None):
        if fullname.split('.')[0] in {'mlx', 'mlx_lm', 'mlx_audio', 'torch', 'transformers'}:
            raise AssertionError('Backend import forbidden')
sys.meta_path.insert(0, NoBackends())
sys.path.insert(0, sys.argv[1])
class Engine:
    def __init__(self, *args): pass
class Generation:
    def __init__(self, engine, prompt, schema=None, thinking=False, prefix='', **kwargs):
        if prompt == 'volatile-cache' and kwargs.get('_use_prefix_cache', True):
            raise RuntimeError('Synthetic volatile request entered prefix cache')
        self.identity = hashlib.sha256(prompt.encode()).hexdigest()
        self.prompt = prompt
        self.wire = self.text = prefix
        self.thinking_count = self.final_count = 0
    def step(self):
        if self.prompt == 'fail':
            raise RuntimeError('SYNTHETIC_PRIVATE_SENTENCE private-location')
        time.sleep(.005)
        self.wire += 'x'
        self.text = self.wire
        self.final_count += 1
        return 'running' if self.prompt.startswith('slow') else 'done'
    def save(self, path): Path(path).write_bytes(b'synthetic checkpoint')
    @classmethod
    def restore(cls, *args): raise RuntimeError('SYNTHETIC_PRIVATE_SENTENCE restore')
engine = types.ModuleType('engine')
engine.Engine, engine.Generation = Engine, Generation
sys.modules['engine'] = engine
schemas = types.ModuleType('schemas')
schemas.note_schema = schemas.review_schema = lambda data: {}
sys.modules['schemas'] = schemas
import worker
worker.discover_mlx = lambda: None
sys.argv = ['worker', '--model', 'stub', '--state-directory', sys.argv[2]]
worker.main()
'''


class WorkerPrivacyTests(unittest.TestCase):
    @contextlib.contextmanager
    def session(self, setup=None):
        with tempfile.TemporaryDirectory(prefix='ll-runtime-privacy-') as directory:
            directory = Path(directory)
            if setup:
                setup(directory)
            with WorkerSession(directory, checkpoint_bytes=32, boot=BOOT) as worker:
                worker.await_ready()
                yield directory, worker

    def error_event(self, worker):
        for _ in range(20):
            event = worker._events.get(timeout=3)
            if event.get('event') == 'error':
                return event
        self.fail('Worker did not report the synthetic failure')

    def test_nonretaining_completion_never_creates_checkpoint(self):
        with self.session() as (directory, worker):
            worker.send(**note_command('a', 'fast'), retainCheckpoint=False)
            self.assertEqual(worker.wait_for('done', 'a')['text'], 'x')
            self.assertEqual(list(directory.glob('*.safetensors')), [])
            worker.shutdown()

    def test_nonretaining_request_forces_prefix_cache_off(self):
        with self.session() as (directory, worker):
            worker.send(**note_command('a', 'volatile-cache'), retainCheckpoint=False, usePrefixCache=True)
            self.assertEqual(worker.wait_for('done', 'a')['text'], 'x')
            self.assertEqual(list(directory.glob('*.safetensors')), [])
            worker.shutdown()

    def test_nonretaining_checkpoint_pause_and_shutdown_stay_in_memory(self):
        with self.session() as (directory, worker):
            worker.send(**note_command('a', 'slow'), retainCheckpoint=False)
            worker.wait_for('snapshot', 'a')
            worker.send('checkpoint', id='a')
            worker.wait_for('checkpoint', 'a')
            self.assertEqual(list(directory.glob('*.safetensors')), [])
            worker.send('pause', id='a')
            worker.wait_for('paused', 'a')
            self.assertEqual(list(directory.glob('*.safetensors')), [])
            worker.shutdown()
            self.assertEqual(list(directory.glob('*.safetensors')), [])

    def test_nonretaining_active_shutdown_does_not_save(self):
        with self.session() as (directory, worker):
            worker.send(**note_command('a', 'slow'), retainCheckpoint=False)
            worker.wait_for('snapshot', 'a')
            worker.shutdown()
            self.assertEqual(list(directory.glob('*.safetensors')), [])

    def test_retained_active_shutdown_still_saves(self):
        with self.session() as (directory, worker):
            worker.send(**note_command('a', 'slow'), retainCheckpoint=True)
            worker.wait_for('snapshot', 'a')
            worker.shutdown()
            self.assertTrue(checkpoint_path(directory, 'slow').is_file())

    def test_false_failure_preserves_matching_unowned_old_record(self):
        def setup(directory):
            checkpoint_path(directory, 'fail').write_bytes(b'old owned record')
            checkpoint_path(directory, 'other').write_bytes(b'other record')
        with self.session(setup) as (directory, worker):
            worker.send(**note_command('a', 'fail'), retainCheckpoint=False)
            error = self.error_event(worker)
            self.assertNotIn(CANARY, json.dumps(error))
            self.assertEqual(checkpoint_path(directory, 'fail').read_bytes(), b'old owned record')
            self.assertEqual(checkpoint_path(directory, 'other').read_bytes(), b'other record')

    def test_discard_deletes_owned_result_and_preserves_unowned_pending(self):
        for prompt in ('fast', 'slow'):
            with self.subTest(prompt=prompt), self.session() as (directory, worker):
                worker.send(**note_command('a', prompt))
                if prompt == 'slow':
                    worker.wait_for('snapshot', 'a')
                    worker.send('pause', id='a')
                    worker.wait_for('paused', 'a')
                else:
                    worker.wait_for('done', 'a')
                path = checkpoint_path(directory, prompt)
                pending = path.with_name(path.stem + '.pending.safetensors')
                pending.write_bytes(b'partial')
                worker.send('discard', id='a', controlID='discard-a')
                receipt = worker.wait_for('discard', 'a')
                self.assertEqual(receipt['controlID'], 'discard-a')
                self.assertFalse(path.exists())
                self.assertEqual(pending.read_bytes(), b'partial')
                worker.shutdown()

    def test_saved_pause_false_request_cancel_keeps_saved_bytes_and_hot_cache(self):
        with self.session() as (directory, worker):
            worker.send(**note_command('saved', 'slow'))
            worker.wait_for('snapshot', 'saved')
            worker.send('pause', id='saved')
            worker.wait_for('paused', 'saved')
            path = checkpoint_path(directory, 'slow')
            previous = path.read_bytes()
            worker.send(**note_command('temporary', 'slow'), prefix='x', retainCheckpoint=False)
            receipt = worker.wait_for('snapshot', 'temporary')
            self.assertFalse(receipt['recovered'])
            worker.send('pause', id='temporary')
            worker.wait_for('paused', 'temporary')
            worker.send('cancel', id='temporary')
            worker.wait_for('cancel', 'temporary')
            self.assertEqual(path.read_bytes(), previous)
            worker.send(**note_command('resumed', 'slow'), prefix='x')
            self.assertTrue(worker.wait_for('snapshot', 'resumed')['recovered'])
            worker.send('pause', id='resumed')
            worker.wait_for('paused', 'resumed')
            worker.shutdown()

    def test_fresh_retained_cancel_preserves_matching_unowned_history(self):
        def setup(directory):
            checkpoint_path(directory, 'slow').write_bytes(b'history')
        with self.session(setup) as (directory, worker):
            worker.send(**note_command('fresh', 'slow'))
            worker.wait_for('snapshot', 'fresh')
            worker.send('cancel', id='fresh')
            worker.wait_for('cancel', 'fresh')
            self.assertEqual(checkpoint_path(directory, 'slow').read_bytes(), b'history')
            worker.shutdown()

    def test_cancel_preserves_a_record_replaced_by_another_owner(self):
        with self.session() as (directory, worker):
            worker.send(**note_command('saved', 'fast'))
            worker.wait_for('done', 'saved')
            replacement = directory / 'replacement'
            replacement.write_bytes(b'other owner')
            os.replace(replacement, checkpoint_path(directory, 'fast'))
            worker.send('cancel', id='saved')
            worker.wait_for('cancel', 'saved')
            self.assertEqual(checkpoint_path(directory, 'fast').read_bytes(), b'other owner')
            worker.shutdown()

    def test_invalid_retain_flag_is_rejected_before_loading(self):
        with self.session() as (directory, worker):
            worker.send(**note_command('a', 'fast'), retainCheckpoint='false')
            self.assertFalse(self.error_event(worker)['recoverable'])
            self.assertEqual(list(directory.glob('*.safetensors')), [])

    def test_state_validation_preserves_existing_modes_and_unknown_pending(self):
        def setup(directory):
            directory.chmod(0o755)
            checkpoint_path(directory, 'old').write_bytes(b'old')
            checkpoint_path(directory, 'old').chmod(0o644)
            (directory / ('a' * 64 + '.pending.safetensors')).write_bytes(b'partial')
            (directory / ('a' * 64 + '.' + 'c' * 32 + '.pending.safetensors')).write_bytes(b'active writer')
            (directory / 'unrelated.pending.safetensors').write_bytes(b'keep')
        with tempfile.TemporaryDirectory(prefix='ll-state-migration-') as directory:
            directory = Path(directory)
            setup(directory)
            for _ in range(2):
                with WorkerSession(directory, checkpoint_bytes=32, boot=BOOT) as worker:
                    worker.await_ready()
                    self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o755)
                    self.assertEqual(stat.S_IMODE(checkpoint_path(directory, 'old').stat().st_mode), 0o644)
                    for name, data in (('a' * 64 + '.pending.safetensors', b'partial'),
                                       ('a' * 64 + '.' + 'c' * 32 + '.pending.safetensors', b'active writer')):
                        self.assertEqual((directory / name).read_bytes(), data)
                        self.assertEqual(stat.S_IMODE((directory / name).stat().st_mode), 0o644)
                    self.assertEqual((directory / 'unrelated.pending.safetensors').read_bytes(), b'keep')
                    worker.shutdown()


def generation_class():
    """Compile the production class without importing its GPU dependencies."""
    source = ast.parse((ROOT / 'engine.py').read_text())
    node = next(item for item in source.body if isinstance(item, ast.ClassDef) and item.name == 'Generation')
    namespace = {'Path': Path, 'os': os, 'json': json}
    try:
        checkpoints = importlib.import_module('checkpoints')
    except ModuleNotFoundError:
        pass
    else:
        for name in ('atomic_checkpoint', 'load_checkpoint'):
            namespace[name] = getattr(checkpoints, name)
    exec(compile(ast.Module(body=[node], type_ignores=[]), 'isolated_generation', 'exec'), namespace)
    return namespace['Generation'], namespace


class CheckpointPrivacyTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix='ll-private-checkpoint-')
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.path = self.directory / ('b' * 64 + '.safetensors')
        cls, self.namespace = generation_class()
        self.generation = object.__new__(cls)
        for name, value in dict(identity='b' * 64, spec={}, initial_prefix='synthetic', pending=[],
                                ids=[], final_ids=[], key=types.SimpleNamespace(tolist=lambda: [1, 2]),
                                phase='final', thinking_count=0, final_count=0, done=True, cache=[]).items():
            setattr(self.generation, name, value)
        self.namespace['mx'] = types.SimpleNamespace(save_safetensors=self.write)
        self.namespace['save_prompt_cache'] = self.write

    @staticmethod
    def write(path, *args):
        Path(path).write_bytes(b'synthetic checkpoint')

    @staticmethod
    def acl_entries(path):
        listing = subprocess.run(['/bin/ls', '-led', str(path)], check=True,
                                 capture_output=True, text=True).stdout
        return re.findall(r'^\s*\d+:\s*(.*)$', listing, re.MULTILINE)

    @staticmethod
    def add_acl(path, entry):
        subprocess.run(['/bin/chmod', '+a', entry, str(path)],
                       check=True, capture_output=True)

    def permissions(self, path):
        entries = self.acl_entries(path) if sys.platform == 'darwin' else []
        return stat.S_IMODE(path.stat().st_mode), entries

    def assert_kernel_write_denied(self):
        with self.assertRaises(PermissionError):
            fd = os.open(self.path, os.O_WRONLY | os.O_NOFOLLOW)
            os.close(fd)

    def test_failed_write_removes_pending_and_preserves_previous_checkpoint(self):
        for done in (False, True):
            with self.subTest(done=done):
                self.path.write_bytes(b'previous')
                self.generation.done = done
                def fail(path, *args):
                    Path(path).write_bytes(b'partial')
                    raise OSError(CANARY)
                self.namespace['mx'].save_safetensors = fail
                self.namespace['save_prompt_cache'] = fail
                with self.assertRaises(OSError):
                    self.generation.save(self.path)
                self.assertEqual(self.path.read_bytes(), b'previous')
                self.assertEqual(list(self.directory.glob('*.pending.safetensors')), [])

    def test_failed_replace_removes_pending(self):
        self.path.write_bytes(b'previous')
        with patch.object(os, 'replace', side_effect=OSError('synthetic replace failure')):
            with self.assertRaises(OSError):
                self.generation.save(self.path)
        self.assertEqual(self.path.read_bytes(), b'previous')
        self.assertEqual(list(self.directory.glob('*.pending.safetensors')), [])

    def test_unique_writes_preserve_other_pending_and_can_overlap(self):
        checkpoints = importlib.import_module('checkpoints')
        legacy = self.path.with_name(self.path.stem + '.pending.safetensors')
        legacy.write_bytes(b'legacy writer')
        historical = self.path.with_name(self.path.stem + '.' + 'c' * 32 + '.pending.safetensors')
        historical.write_bytes(b'unknown writer')
        created = []
        def inner(path):
            created.append(Path(path))
            self.assertNotEqual(created[0], created[1])
            self.assertEqual(created[0].read_bytes(), b'outer progress')
            Path(path).write_bytes(b'inner result')
        def outer(path):
            created.append(Path(path))
            self.assertNotIn(Path(path), (legacy, historical))
            Path(path).write_bytes(b'outer progress')
            checkpoints.atomic_checkpoint(self.path, inner)
            raise OSError('synthetic outer failure')
        with self.assertRaises(OSError):
            checkpoints.atomic_checkpoint(self.path, outer)
        self.assertEqual(self.path.read_bytes(), b'inner result')
        self.assertEqual(legacy.read_bytes(), b'legacy writer')
        self.assertEqual(historical.read_bytes(), b'unknown writer')
        self.assertEqual(set(self.directory.glob('*.pending.safetensors')), {legacy, historical})

    def test_cleanup_preserves_pending_replaced_by_another_inode(self):
        checkpoints = importlib.import_module('checkpoints')
        created = []
        def replace_then_fail(path):
            created.append(Path(path))
            foreign = self.directory / 'foreign'
            foreign.write_bytes(b'other writer')
            os.replace(foreign, path)
            raise OSError('synthetic replaced pending')
        with self.assertRaises(OSError):
            checkpoints.atomic_checkpoint(self.path, replace_then_fail)
        self.assertEqual(created[0].read_bytes(), b'other writer')
        self.assertFalse(self.path.exists())

    def test_existing_modes_are_preserved_on_every_save(self):
        for _ in range(2):
            self.directory.chmod(0o755)
            self.path.write_bytes(b'previous')
            self.path.chmod(0o644)
            self.generation.save(self.path)
            self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o755)
            self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o644)

    def test_new_directories_and_checkpoint_are_private(self):
        checkpoints = importlib.import_module('checkpoints')
        self.directory.chmod(0o755)
        path = self.directory / 'new' / 'nested' / self.path.name
        checkpoints.atomic_checkpoint(path, self.write)
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o755)
        for directory in (path.parent.parent, path.parent):
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(path.read_bytes(), b'synthetic checkpoint')

    def test_readers_and_getters_preserve_existing_modes(self):
        checkpoints = importlib.import_module('checkpoints')
        self.directory.chmod(0o755)
        self.path.write_bytes(b'previous')
        self.path.chmod(0o644)
        for _ in range(2):
            checkpoints.prepare_state_directory(self.directory)
            self.assertIsNotNone(checkpoints.checkpoint_token(self.directory, self.path.stem))
            self.assertEqual(len(checkpoints.checkpoint_records(self.directory)), 1)
            self.assertEqual(checkpoints.load_checkpoint(self.path, lambda path: Path(path).read_bytes()),
                             b'previous')
            self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o755)
            self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o644)

    def test_missing_runtime_getters_do_not_create_directories(self):
        checkpoints = importlib.import_module('checkpoints')
        missing = self.directory / 'missing'
        self.assertIsNone(checkpoints.checkpoint_token(missing, self.path.stem))
        self.assertEqual(checkpoints.checkpoint_records(missing), [])
        self.assertFalse(missing.exists())

    def test_read_only_target_is_rejected_before_serialization(self):
        checkpoints = importlib.import_module('checkpoints')
        self.path.write_bytes(b'previous')
        self.path.chmod(0o400)
        previous = self.path.stat().st_ino, self.permissions(self.path)
        self.assert_kernel_write_denied()
        writes = []
        with self.assertRaises(PermissionError):
            checkpoints.atomic_checkpoint(self.path, lambda path: writes.append(path))
        self.assertEqual(writes, [])
        self.assertEqual((self.path.stat().st_ino, self.permissions(self.path)), previous)
        self.assertEqual(self.path.read_bytes(), b'previous')
        self.assertEqual(list(self.directory.glob('*.pending.safetensors')), [])

    def test_write_access_is_rechecked_after_serialization(self):
        checkpoints = importlib.import_module('checkpoints')
        self.path.write_bytes(b'previous')
        inode = self.path.stat().st_ino
        def revoke_write(path):
            self.write(path)
            self.path.chmod(0o400)
        with self.assertRaises(PermissionError):
            checkpoints.atomic_checkpoint(self.path, revoke_write)
        self.assertEqual(self.path.stat().st_ino, inode)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o400)
        self.assertEqual(self.path.read_bytes(), b'previous')
        self.assertEqual(list(self.directory.glob('*.pending.safetensors')), [])

    def test_target_replaced_during_serialization_is_preserved(self):
        checkpoints = importlib.import_module('checkpoints')
        self.path.write_bytes(b'previous')
        def another_writer(path):
            self.write(path)
            replacement = self.directory / 'another-record'
            replacement.write_bytes(b'another writer')
            replacement.chmod(0o640)
            os.replace(replacement, self.path)
        with self.assertRaisesRegex(checkpoints.CheckpointSafetyError, 'changed'):
            checkpoints.atomic_checkpoint(self.path, another_writer)
        self.assertEqual(self.path.read_bytes(), b'another writer')
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o640)
        self.assertEqual(list(self.directory.glob('*.pending.safetensors')), [])

    def test_new_directory_replaced_before_open_keeps_existing_permissions(self):
        checkpoints = importlib.import_module('checkpoints')
        foreign = self.directory / 'foreign'
        foreign.mkdir()
        foreign.chmod(0o755)
        (foreign / 'body').write_bytes(b'another directory')
        if sys.platform == 'darwin':
            self.add_acl(foreign, 'everyone allow list,search,readattr,readsecurity')
        previous = self.permissions(foreign)
        original_open = os.open
        changed = []
        def replace_before_open(name, flags, *args, **kwargs):
            if name == 'created' and not changed:
                changed.append(True)
                fd = kwargs['dir_fd']
                os.rename('created', 'unused-created', src_dir_fd=fd, dst_dir_fd=fd)
                os.rename('foreign', 'created', src_dir_fd=fd, dst_dir_fd=fd)
            return original_open(name, flags, *args, **kwargs)
        with patch.object(os, 'open', side_effect=replace_before_open):
            with self.assertRaisesRegex(checkpoints.CheckpointSafetyError, 'changed'):
                checkpoints.prepare_state_directory(self.directory / 'created')
        self.assertEqual(self.permissions(self.directory / 'created'), previous)
        self.assertEqual((self.directory / 'created/body').read_bytes(), b'another directory')

    def test_owner_read_only_restrictions_are_preserved(self):
        checkpoints = importlib.import_module('checkpoints')
        self.path.write_bytes(b'synthetic read-only body')
        self.path.chmod(0o400)
        self.directory.chmod(0o500)
        self.addCleanup(self.directory.chmod, 0o700)
        for _ in range(2):
            checkpoints.prepare_state_directory(self.directory)
            self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o500)
            self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o400)
            self.assertEqual(self.path.read_bytes(), b'synthetic read-only body')

    def test_symlink_directory_is_rejected_without_writing_through_it(self):
        target = self.directory / 'target'
        target.mkdir()
        link = self.directory / 'linked'
        link.symlink_to(target, target_is_directory=True)
        with self.assertRaises((OSError, ValueError)):
            self.generation.save(link / self.path.name)
        self.assertEqual(list(target.iterdir()), [])

    def test_symlink_leaf_is_rejected_without_replacing_it(self):
        target = self.directory / 'unrelated'
        target.write_bytes(b'keep')
        self.path.symlink_to(target)
        with self.assertRaises((OSError, ValueError)):
            self.generation.save(self.path)
        self.assertTrue(self.path.is_symlink())
        self.assertEqual(target.read_bytes(), b'keep')

    def test_foreign_owner_is_rejected(self):
        with patch.object(os, 'getuid', return_value=os.getuid() + 1):
            with self.assertRaises((OSError, ValueError)):
                self.generation.save(self.path)
        self.assertFalse(self.path.exists())

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS extended ACL regression')
    def test_existing_mode_and_acl_are_preserved_on_replacement(self):
        self.path.write_bytes(b'previous')
        self.directory.chmod(0o755)
        self.path.chmod(0o640)
        self.add_acl(self.directory,
                     'everyone allow read,readattr,readextattr,readsecurity,file_inherit,directory_inherit')
        self.add_acl(self.path, 'everyone deny writeextattr')
        self.add_acl(self.path, 'everyone allow read,readattr,readextattr,readsecurity')
        previous = {path: self.permissions(path) for path in (self.directory, self.path)}
        for _ in range(2):
            self.generation.save(self.path)
            self.assertEqual(self.path.read_bytes(), b'synthetic checkpoint')
            for path in previous:
                self.assertEqual(self.permissions(path), previous[path])

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS extended ACL regression')
    def test_acl_only_read_and_directory_access_survive_runtime_getters(self):
        checkpoints = importlib.import_module('checkpoints')
        self.path.write_bytes(b'previous')
        self.add_acl(self.path, 'everyone allow read,readattr,readextattr,readsecurity')
        self.add_acl(self.directory, 'everyone allow list,search,readattr,readextattr,readsecurity')
        self.path.chmod(0o000)
        self.directory.chmod(0o300)
        self.addCleanup(self.directory.chmod, 0o700)
        previous = {path: self.permissions(path) for path in (self.directory, self.path)}
        self.assertEqual(self.path.read_bytes(), b'previous')
        self.assertIn(self.path.name, os.listdir(self.directory))
        for _ in range(2):
            checkpoints.prepare_state_directory(self.directory)
            self.assertIsNotNone(checkpoints.checkpoint_token(self.directory, self.path.stem))
            self.assertEqual(len(checkpoints.checkpoint_records(self.directory)), 1)
            self.assertEqual(checkpoints.load_checkpoint(self.path, lambda path: Path(path).read_bytes()),
                             b'previous')
            for path in previous:
                self.assertEqual(self.permissions(path), previous[path])

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS extended ACL regression')
    def test_new_inherited_allow_is_removed_and_deny_is_preserved(self):
        checkpoints = importlib.import_module('checkpoints')
        self.directory.chmod(0o755)
        self.add_acl(self.directory,
                     'everyone allow read,readattr,readextattr,readsecurity,file_inherit,directory_inherit')
        self.add_acl(self.directory, 'everyone deny writeextattr,file_inherit,directory_inherit')
        previous = self.permissions(self.directory)
        path = self.directory / 'new' / 'nested' / self.path.name
        checkpoints.atomic_checkpoint(path, self.write)
        self.assertEqual(self.permissions(self.directory), previous)
        for created, mode in ((path.parent.parent, 0o700), (path.parent, 0o700), (path, 0o600)):
            self.assertEqual(stat.S_IMODE(created.stat().st_mode), mode)
            entries = self.acl_entries(created)
            self.assertTrue(any('deny writeextattr' in entry for entry in entries))
            self.assertFalse(any(' allow ' in ' ' + entry for entry in entries))
        self.assertEqual(path.read_bytes(), b'synthetic checkpoint')

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS extended ACL regression')
    def test_replacement_preserves_new_inherited_denials_idempotently(self):
        checkpoints = importlib.import_module('checkpoints')
        self.path.write_bytes(b'previous')
        self.path.chmod(0o644)
        self.add_acl(self.path, 'everyone allow read,readattr,readextattr,readsecurity')
        old_entries = self.acl_entries(self.path)
        self.add_acl(self.directory, 'everyone deny writeextattr,file_inherit,directory_inherit')
        parent_permissions = self.permissions(self.directory)
        snapshots = []
        for _ in range(2):
            checkpoints.atomic_checkpoint(self.path, self.write)
            self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o644)
            self.assertEqual(self.permissions(self.directory), parent_permissions)
            entries = self.acl_entries(self.path)
            self.assertEqual(entries[:len(old_entries)], old_entries)
            self.assertTrue(any('deny writeextattr' in entry for entry in entries))
            snapshots.append(entries)
        self.assertEqual(snapshots[0], snapshots[1])
        self.assertEqual(self.path.read_bytes(), b'synthetic checkpoint')

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS extended ACL regression')
    def test_acl_deny_write_is_rejected_before_serialization(self):
        checkpoints = importlib.import_module('checkpoints')
        self.path.write_bytes(b'previous')
        self.path.chmod(0o600)
        self.add_acl(self.path, 'everyone deny write,append')
        previous = self.path.stat().st_ino, self.permissions(self.path)
        self.assert_kernel_write_denied()
        writes = []
        with self.assertRaises(PermissionError):
            checkpoints.atomic_checkpoint(self.path, lambda path: writes.append(path))
        self.assertEqual(writes, [])
        self.assertEqual((self.path.stat().st_ino, self.permissions(self.path)), previous)
        self.assertEqual(self.path.read_bytes(), b'previous')
        self.assertEqual(list(self.directory.glob('*.pending.safetensors')), [])

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS extended ACL regression')
    def test_acl_granted_write_preserves_mode_and_effective_access(self):
        checkpoints = importlib.import_module('checkpoints')
        self.path.write_bytes(b'previous')
        self.path.chmod(0o400)
        self.add_acl(self.path, 'everyone allow read,write,append,readattr,readextattr,readsecurity')
        previous = self.permissions(self.path)
        fd = os.open(self.path, os.O_WRONLY | os.O_NOFOLLOW)
        os.close(fd)
        checkpoints.atomic_checkpoint(self.path, self.write)
        self.assertEqual(self.permissions(self.path), previous)
        self.assertEqual(self.path.read_bytes(), b'synthetic checkpoint')
        fd = os.open(self.path, os.O_WRONLY | os.O_NOFOLLOW)
        os.close(fd)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS extended ACL regression')
    def test_acl_write_revoked_during_serialization_keeps_old_bytes(self):
        checkpoints = importlib.import_module('checkpoints')
        self.path.write_bytes(b'previous')
        inode = self.path.stat().st_ino
        def revoke_write(path):
            self.write(path)
            self.add_acl(self.path, 'everyone deny write,append')
        with self.assertRaises(PermissionError):
            checkpoints.atomic_checkpoint(self.path, revoke_write)
        self.assertEqual(self.path.stat().st_ino, inode)
        self.assertEqual(self.path.read_bytes(), b'previous')
        self.assertTrue(any('deny write,append' in entry for entry in self.acl_entries(self.path)))
        self.assert_kernel_write_denied()
        self.assertEqual(list(self.directory.glob('*.pending.safetensors')), [])

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS extended ACL regression')
    def test_acl_denials_are_preserved_idempotently(self):
        checkpoints = importlib.import_module('checkpoints')
        self.path.write_bytes(b'previous')
        subprocess.run(['/bin/chmod', '+a', 'everyone deny writeextattr', str(self.path)],
                       check=True, capture_output=True)
        subprocess.run(['/bin/chmod', '+a', 'everyone allow read,readattr,readextattr,readsecurity', str(self.path)],
                       check=True, capture_output=True)
        fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            snapshots = []
            for _ in range(2):
                checkpoints._strip_extended_acl(fd)
                listing = subprocess.run(['/bin/ls', '-le', str(self.path)], check=True,
                                         capture_output=True, text=True).stdout
                entries = re.findall(r'^\s*\d+:\s*(.*)$', listing, re.MULTILINE)
                self.assertTrue(any('deny writeextattr' in entry for entry in entries))
                self.assertFalse(any(' allow ' in ' ' + entry for entry in entries))
                snapshots.append(entries)
            self.assertEqual(snapshots[0], snapshots[1])
            self.assertEqual(self.path.read_bytes(), b'previous')
        finally:
            os.close(fd)

    def test_zero_return_with_nil_acl_entry_is_empty(self):
        checkpoints = importlib.import_module('checkpoints')
        fake = types.SimpleNamespace(acl_get_fd_np=lambda *args: 1,
                                     acl_get_entry=lambda *args: 0, acl_free=lambda *args: 0)
        self.path.write_bytes(b'synthetic')
        fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            with patch.object(checkpoints, '_ACL_API', fake), patch.object(sys, 'platform', 'darwin'):
                checkpoints._strip_extended_acl(fd)
        finally:
            os.close(fd)

    def test_checkpoint_metadata_utf8_bytes_are_unchanged(self):
        self.generation.initial_prefix = '合成前缀：'
        expected = dict(version=2, identity='b' * 64, spec={}, prefix='合成前缀：', pending=[],
                        ids=[], final_ids=[], key=[1, 2], phase='final', thinking_count=0,
                        final_count=0, done=True)
        captured = []
        def capture(path, arrays, metadata):
            captured.append(metadata)
            self.write(path)
        self.namespace['mx'].save_safetensors = capture
        self.generation.save(self.path)
        self.assertEqual(captured[0]['livelingo.completed'].encode('utf-8'),
                         json.dumps(expected, ensure_ascii=False).encode('utf-8'))


class DiagnosticPrivacyTests(unittest.TestCase):
    def test_plain_dependency_errors_are_never_forwarded(self):
        self.assertNotIn(CANARY, generation_detail(RuntimeError(CANARY)))
        self.assertNotIn(CANARY, failure_line('generation', 'generation_failed', CANARY))

    def test_ascii_field_and_stage_names_cannot_smuggle_payload(self):
        line = failure_line(CANARY, CANARY, '', field='evidence[0].' + CANARY, request=CANARY)
        self.assertNotIn(CANARY, line)

    def test_unexpected_input_key_is_not_echoed_as_a_field_name(self):
        data = {'reviewVersion': 2, 'note': {'points': []},
                'evidence': [{'index': 0, 'quotes': [], CANARY: 'synthetic'}]}
        with self.assertRaises(ValueError) as caught:
            parse_review_input(json.dumps(data))
        self.assertNotIn(CANARY, str(caught.exception))

    def test_structured_error_cannot_be_constructed_from_free_text(self):
        error = ReviewFailure(CANARY)
        self.assertNotIn(CANARY, safe_error_message(error, review=True))


if __name__ == '__main__':
    unittest.main()
