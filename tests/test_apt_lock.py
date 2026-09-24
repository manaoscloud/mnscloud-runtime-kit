"""apt/dpkg lock wait contract for lib/apt.sh, using stub lslocks/apt-get (no root)."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AptLockTest(unittest.TestCase):
    def run_helper(self, held_polls, timeout='600', extra_env=None):
        with tempfile.TemporaryDirectory() as folder:
            stub = Path(folder)
            counter = stub / 'polls'
            counter.write_text('0')
            # lslocks reports the dpkg frontend lock for the first `held_polls` polls.
            (stub / 'lslocks').write_text(
                '#!/usr/bin/env bash\n'
                f'n=$(cat {counter}); echo $((n + 1)) > {counter}\n'
                f'if (( n < {held_polls} )); then echo /var/lib/dpkg/lock-frontend; fi\n'
                'echo /run/unrelated.lock\n')
            (stub / 'apt-get').write_text(
                '#!/usr/bin/env bash\n'
                f'echo "apt-get $* APT_CONFIG=$(cat "$APT_CONFIG")" > {stub}/apt-called\n')
            (stub / 'sleep').write_text('#!/usr/bin/env bash\nexit 0\n')
            for name in ('lslocks', 'apt-get', 'sleep'):
                os.chmod(stub / name, 0o755)
            env = {'PATH': f'{stub}:/usr/bin:/bin', 'TMPDIR': folder,
                   'MNSCLOUD_APT_LOCK_TIMEOUT': timeout, **(extra_env or {})}
            result = subprocess.run(
                ['bash', '-c', f'source {ROOT}/lib/apt.sh && mrtk_apt_get install -y curl'],
                env=env, capture_output=True, text=True, timeout=30)
            called = (stub / 'apt-called').read_text() if (stub / 'apt-called').exists() else ''
            return result, called, int(counter.read_text())

    def test_waits_until_lock_is_released(self):
        result, called, polls = self.run_helper(held_polls=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(polls, 4)
        self.assertIn('waiting for another apt/dpkg process', result.stdout)
        self.assertIn('apt-get install -y curl', called)
        self.assertIn('DPkg::Lock::Timeout "600";', called)

    def test_runs_immediately_without_lock(self):
        result, called, polls = self.run_helper(held_polls=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(polls, 1)
        self.assertNotIn('waiting', result.stdout)
        self.assertTrue(called)

    def test_timeout_still_runs_apt_to_report_holder(self):
        result, called, _ = self.run_helper(held_polls=1000, timeout='10')
        self.assertIn('still held after 10s', result.stderr)
        self.assertIn('DPkg::Lock::Timeout "10";', called)

    def test_keeps_caller_apt_config(self):
        with tempfile.NamedTemporaryFile('w', suffix='.conf') as custom:
            custom.write('Custom "1";\n')
            custom.flush()
            _, called, _ = self.run_helper(held_polls=0, extra_env={'APT_CONFIG': custom.name})
        self.assertIn('Custom "1";', called)

    def test_packages_library_uses_lock_aware_apt(self):
        for line in (ROOT / 'lib/packages.sh').read_text().splitlines():
            stripped = line.strip()
            if stripped.startswith('#') or 'command -v apt-get' in stripped:
                continue
            self.assertNotRegex(stripped, r'(^|\s|&&|\|\|)apt-get\s', line)


if __name__ == '__main__':
    unittest.main()
