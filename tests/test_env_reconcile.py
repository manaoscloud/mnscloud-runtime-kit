import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("env_reconcile", Path(__file__).resolve().parents[1] / "lib/env_reconcile.py")
m = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = m
SPEC.loader.exec_module(m)
RULES = (m.Rule("SHARED_KEY", "initialize"), m.Rule("HANDLERS", "add-set"), m.Rule("SETTING", "managed"))


class CandidateTests(unittest.TestCase):
    def test_preserves_unrelated_and_adds_only_missing_members(self):
        before = b'# preserved\nOTHER="x y"\nHANDLERS=smtp,storage\n'
        wanted = {"HANDLERS": "dns"}
        after = m.candidate(before, RULES, wanted)
        self.assertEqual(after, before.replace(b'smtp,storage', b'smtp,storage,dns'))
        self.assertEqual(m.candidate(after, RULES, wanted), after)

    def test_secret_initialization_and_no_rotation(self):
        result = m.candidate(b'OTHER=1', RULES, {"SHARED_KEY": "secret-one"})
        self.assertEqual(result, b'OTHER=1\nSHARED_KEY=secret-one\n')
        self.assertEqual(m.candidate(result, RULES, {"SHARED_KEY": "secret-one"}), result)
        with self.assertRaisesRegex(m.ReconcileError, '^EXISTING_VALUE_CONFLICT$'):
            m.candidate(result, RULES, {"SHARED_KEY": "secret-two"})

    def test_three_way_conflict(self):
        with self.assertRaisesRegex(m.ReconcileError, '^LOCAL_DRIFT_CONFLICT$'):
            m.candidate(b'SETTING=local\n', RULES, {"SETTING": "new"}, {"SETTING": "old"})
        self.assertEqual(m.candidate(b'SETTING=old\n', RULES, {"SETTING": "new"}, {"SETTING": "old"}), b'SETTING=new\n')

    def test_rejects_duplicates_unknown_keys_and_injections(self):
        cases = [
            (b'SHARED_KEY=one\nexport SHARED_KEY=two\n', {"SHARED_KEY": "three"}),
            (b'', {"UNSUPPORTED": "one"}),
            (b'', {"SHARED_KEY": 'x\nINJECTED=1'}),
            (b'SHARED_KEY="$(secret-command)"\n', {"SHARED_KEY": 'x'}),
            (b'OTHER="multiline\nSHARED_KEY=hidden\n"\n', {"SHARED_KEY": 'x'}),
            (b'SHARED_KEY=x\x00', {"SHARED_KEY": 'x'}),
            (b'HANDLERS=smtp,,storage\n', {"HANDLERS": 'dns'}),
        ]
        for source, desired in cases:
            with self.subTest(source=source), self.assertRaises(m.ReconcileError):
                m.candidate(source, RULES, desired)


class JournalTests(unittest.TestCase):
    def setUp(self):
        # Secure path traversal intentionally rejects /tmp and other writable ancestors.
        self.root = Path(tempfile.mkdtemp(prefix='.reconcile-test-', dir=Path.home()))
        self.addCleanup(shutil.rmtree, self.root)
        self.config = self.root / 'runtime.env'
        self.config.write_text('OTHER=preserve\nHANDLERS=smtp\n')
        self.config.chmod(0o640)
        self.journal = self.root / 'journal'
        self.journal.mkdir(mode=0o700)
        self.adapter = m.EnvJournal(str(self.config), str(self.journal), RULES)
        self.operation = str(uuid.uuid4())

    def test_apply_retry_and_private_before_image(self):
        self.adapter.stage(self.operation, {"SHARED_KEY": "private-value"})
        with patch.object(m, 'atomic_write', wraps=m.atomic_write) as write:
            first = self.adapter.apply(self.operation)
            second = self.adapter.apply(self.operation)
            target_writes = [call for call in write.call_args_list if call.args[1] == 'runtime.env']
            self.assertEqual(len(target_writes), 1)
        self.assertTrue(first["changed"])
        self.assertFalse(second["changed"])
        self.assertNotIn('private-value', json.dumps(first))
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o640)
        saved = self.journal / (self.operation + '.json')
        self.assertEqual(saved.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(saved.read_text())['before'], 'OTHER=preserve\nHANDLERS=smtp\n')

    def test_stale_plan_does_not_replace_local_edit(self):
        self.adapter.stage(self.operation, {"HANDLERS": "dns"})
        self.config.write_text('OTHER=operator-change\nHANDLERS=smtp\n')
        with self.assertRaisesRegex(m.ReconcileError, '^STALE_PLAN$'):
            self.adapter.apply(self.operation)
        self.assertIn('operator-change', self.config.read_text())

    def test_crash_after_replace_recovers_without_second_write(self):
        self.adapter.stage(self.operation, {"HANDLERS": "dns"})
        original = m.EnvJournal.save
        def fail_complete(journal, name, plan):
            if plan['phase'] == 'applied':
                raise OSError('simulated crash')
            original(journal, name, plan)
        with patch.object(m.EnvJournal, 'save', side_effect=fail_complete):
            with self.assertRaises(OSError):
                self.adapter.apply(self.operation)
        self.assertIn('smtp,dns', self.config.read_text())
        with patch.object(m, 'atomic_write', wraps=m.atomic_write) as write:
            self.adapter.apply(self.operation)
            self.assertFalse(any(call.args[1] == 'runtime.env' for call in write.call_args_list))

    def test_failed_write_retains_active_file_and_can_retry(self):
        self.adapter.stage(self.operation, {"HANDLERS": "dns"})
        before = self.config.read_bytes()
        with patch.object(m.os, 'replace', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                self.adapter.apply(self.operation)
        self.assertEqual(self.config.read_bytes(), before)
        self.adapter.apply(self.operation)

    def test_symlink_hardlink_and_journal_permissions_rejected(self):
        self.config.rename(self.root / 'real.env')
        self.config.symlink_to(self.root / 'real.env')
        with self.assertRaises(OSError):
            self.adapter.stage(self.operation, {"HANDLERS": "dns"})
        self.config.unlink()
        os.link(self.root / 'real.env', self.config)
        with self.assertRaisesRegex(m.ReconcileError, '^UNSAFE_FILE$'):
            self.adapter.stage(self.operation, {"HANDLERS": "dns"})
        self.config.unlink()
        (self.root / 'real.env').rename(self.config)
        self.journal.chmod(0o755)
        with self.assertRaisesRegex(m.ReconcileError, '^JOURNAL_NOT_PRIVATE$'):
            self.adapter.stage(self.operation, {"HANDLERS": "dns"})

    def test_lock_blocks_competing_executor(self):
        with self.adapter.locked():
            with self.assertRaises(BlockingIOError):
                self.adapter.stage(self.operation, {"HANDLERS": "dns"})

    def test_reused_operation_cannot_change_desired(self):
        self.adapter.stage(self.operation, {"SHARED_KEY": "one"})
        with self.assertRaisesRegex(m.ReconcileError, '^OPERATION_CONFLICT$'):
            self.adapter.stage(self.operation, {"SHARED_KEY": "two"})

    def test_permissions_changed_after_stage_are_rejected(self):
        self.adapter.stage(self.operation, {"HANDLERS": "dns"})
        self.config.chmod(0o600)
        with self.assertRaisesRegex(m.ReconcileError, '^METADATA_CHANGED$'):
            self.adapter.apply(self.operation)


if __name__ == '__main__':
    unittest.main()
