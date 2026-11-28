"""Contract tests for lib/retention.sh (mrtk_retention_prune) on temporary directories."""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
DAY = 86400


def prune(*args):
    proc = subprocess.run(
        ['bash', '-c', 'source "$1"; shift; mrtk_retention_prune "$@"', 'bash',
         str(ROOT / 'lib' / 'retention.sh'), *args],
        capture_output=True, text=True)
    return proc


class RetentionTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.root = self.tmp / 'root'
        self.root.mkdir()
        self.now = time.time()

    def make(self, name, age_days, size=0, directory=False):
        path = self.root / name
        if directory:
            path.mkdir()
            if size:
                (path / 'blob').write_bytes(b'x' * size)
        else:
            path.write_bytes(b'x' * size)
        stamp = self.now - age_days * DAY
        if directory and size:
            os.utime(path / 'blob', (stamp, stamp))
        os.utime(path, (stamp, stamp))
        return path

    def run_ok(self, *args):
        proc = prune(*args)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = proc.stdout.splitlines()
        self.assertEqual(len(lines), 1, proc.stdout)
        return json.loads(lines[0])

    def names(self):
        return sorted(p.name for p in self.root.iterdir())

    def test_keep_newest_and_min_age(self):
        for i, age in enumerate([1, 10, 20, 30]):
            self.make(f'r-{i}', age)
        out = self.run_ok(str(self.root), r'r-[0-9]+', '2', '15')
        self.assertEqual(out, {'path': str(self.root), 'kept': 2 + 0, 'removed': 2,
                               'freedBytes': out['freedBytes'], 'dryRun': False})
        self.assertEqual(self.names(), ['r-0', 'r-1'])

    def test_min_age_spares_young_entries(self):
        for i, age in enumerate([1, 2, 3, 40]):
            self.make(f'r-{i}', age)
        out = self.run_ok(str(self.root), r'r-.*', '1', '7')
        self.assertEqual((out['kept'], out['removed']), (3, 1))
        self.assertEqual(self.names(), ['r-0', 'r-1', 'r-2'])

    def test_min_age_zero_removes_all_beyond_keep(self):
        for i, age in enumerate([1, 2, 3]):
            self.make(f'r-{i}', age)
        out = self.run_ok(str(self.root), r'r-.*', '1', '0')
        self.assertEqual((out['kept'], out['removed']), (1, 2))
        self.assertEqual(self.names(), ['r-0'])

    def test_protect(self):
        for i, age in enumerate([1, 30, 40, 50]):
            self.make(f'r-{i}', age)
        out = self.run_ok(str(self.root), r'r-.*', '1', '7',
                          '--protect', 'r-2', '--protect', 'r-3')
        self.assertEqual((out['kept'], out['removed']), (3, 1))
        self.assertEqual(self.names(), ['r-0', 'r-2', 'r-3'])

    def test_dry_run_counts_and_freed_bytes(self):
        self.make('a', 1, 10, directory=True)
        d = self.make('b', 30, 50000, directory=True)
        f = self.make('c', 40, 20000)
        expected = 0
        for path in (d, f):
            expected += int(subprocess.check_output(
                ['du', '-s', '-B1', '-x', '--', str(path)]).split()[0])
        dry = self.run_ok(str(self.root), r'[abc]', '1', '7', '--dry-run')
        self.assertEqual(self.names(), ['a', 'b', 'c'])
        self.assertTrue(dry['dryRun'])
        self.assertEqual((dry['kept'], dry['removed'], dry['freedBytes']), (1, 2, expected))
        real = self.run_ok(str(self.root), r'[abc]', '1', '7')
        self.assertFalse(real['dryRun'])
        self.assertEqual((real['kept'], real['removed'], real['freedBytes']), (1, 2, expected))
        self.assertEqual(self.names(), ['a'])

    def test_symlink_child_not_removed_nor_followed(self):
        outside = self.tmp / 'outside'
        outside.mkdir()
        (outside / 'keep.txt').write_text('data')
        os.utime(outside, (self.now - 90 * DAY,) * 2)
        self.make('r-0', 1)
        self.make('r-1', 50)
        link = self.root / 'r-link'
        link.symlink_to(outside)
        os.utime(link, (self.now - 90 * DAY,) * 2, follow_symlinks=False)
        out = self.run_ok(str(self.root), r'r-.*', '1', '7')
        self.assertEqual((out['kept'], out['removed']), (1, 1))
        self.assertTrue(link.is_symlink())
        self.assertTrue((outside / 'keep.txt').exists())
        self.assertEqual(self.names(), ['r-0', 'r-link'])

    def test_missing_root(self):
        missing = self.tmp / 'nope'
        out = self.run_ok(str(missing), r'.*', '1', '0')
        self.assertEqual(out, {'path': str(missing), 'kept': 0, 'removed': 0,
                               'freedBytes': 0, 'dryRun': False, 'missing': True})

    def test_invalid_roots(self):
        target = self.tmp / 'target'
        target.mkdir()
        link = self.tmp / 'rootlink'
        link.symlink_to(target)
        for bad in ('/', 'relative/dir', str(link)):
            proc = prune(bad, r'.*', '1', '0')
            self.assertEqual(proc.returncode, 2, bad)
            self.assertEqual(proc.stdout, '')
            self.assertTrue(proc.stderr.strip(), bad)

    def test_invalid_keep_and_age(self):
        self.make('a', 30)
        for keep in ('0', '-1', 'x', '', '1.5'):
            proc = prune(str(self.root), r'.*', keep, '0')
            self.assertEqual(proc.returncode, 2, keep)
            self.assertTrue(proc.stderr.strip())
        proc = prune(str(self.root), r'.*', '1', 'abc')
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(self.names(), ['a'])

    def test_regex_must_match_fully(self):
        self.make('rel-1', 1)
        self.make('rel-2', 40)
        self.make('xrel-3', 50)
        self.make('rel-4.bak', 60)
        out = self.run_ok(str(self.root), r'rel-[0-9]', '1', '0')
        self.assertEqual((out['kept'], out['removed']), (1, 1))
        self.assertEqual(self.names(), ['rel-1', 'rel-4.bak', 'xrel-3'])

    def test_files_and_directories(self):
        self.make('v1', 1, 10)
        self.make('v2', 30, 10, directory=True)
        self.make('v3', 40, 10)
        out = self.run_ok(str(self.root), r'v[0-9]', '1', '7')
        self.assertEqual((out['kept'], out['removed']), (1, 2))
        self.assertEqual(self.names(), ['v1'])

    def test_hidden_only_when_regex_matches(self):
        self.make('.h1', 1)
        self.make('.h2', 30)
        self.make('v1', 40)
        out = self.run_ok(str(self.root), r'v.*', '1', '0')
        self.assertEqual((out['kept'], out['removed']), (1, 0))
        out = self.run_ok(str(self.root), r'\..*', '1', '0')
        self.assertEqual((out['kept'], out['removed']), (1, 1))
        self.assertEqual(self.names(), ['.h1', 'v1'])

    def test_newline_names_skipped(self):
        self.make('r-0', 1)
        self.make('r-1\nx', 50)
        out = self.run_ok(str(self.root), r'(r-.*|.*\n.*)', '1', '0')
        self.assertEqual(out['removed'], 0)
        self.assertEqual(len(self.names()), 2)

    def test_ties_by_name(self):
        for name in ('a', 'b', 'c'):
            self.make(name, 30)
            os.utime(self.root / name, (self.now - 30 * DAY,) * 2)
        out = self.run_ok(str(self.root), r'[abc]', '1', '7')
        self.assertEqual(out['removed'], 2)
        self.assertEqual(self.names(), ['a'])

    def test_no_side_effects_on_source(self):
        proc = subprocess.run(
            ['bash', '-c', 'set -u; source "$1"; echo "$-"', 'bash',
             str(ROOT / 'lib' / 'retention.sh')], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn('e', proc.stdout.strip())


if __name__ == '__main__':
    unittest.main()
