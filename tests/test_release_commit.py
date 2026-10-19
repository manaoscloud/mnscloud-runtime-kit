import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import textwrap
import unittest
from unittest.mock import patch


class ReleaseCommitTest(unittest.TestCase):
    def payload(self, commit):
        script = (Path(__file__).resolve().parents[1] / 'scripts/notify-release-cache.sh').read_text()
        block = script.split("python3 - > \"$payload\" <<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            manifest = root / 'manifest.json'
            manifest.write_text(json.dumps({'product': 'mnscloud-authentication', 'channels': {'stable': {}}}))
            original_open = open
            def fixture_open(path, *args, **kwargs):
                return original_open(manifest if path == 'releases/manifest.json' else path, *args, **kwargs)
            output = io.StringIO()
            with patch.dict(os.environ, {'RELEASE_VERSION': '0.1.8', 'GITHUB_OUTPUT': str(root / 'output')}), \
                 patch('builtins.open', fixture_open), \
                 patch('subprocess.check_output', return_value=commit + '\n') as git, \
                 contextlib.redirect_stdout(output):
                exec(compile(textwrap.dedent(block), 'release-workflow', 'exec'), {})
                git.assert_called_once_with(['git', 'rev-list', '-n', '1', 'v0.1.8'], text=True)
            return json.loads(output.getvalue())

    def test_publishes_full_tag_commit(self):
        commit = '1234567890abcdef' * 2 + '12345678'
        self.assertEqual(self.payload(commit)['buildRef'], commit)

    def test_web_clients_are_managed_products(self):
        script = (Path(__file__).resolve().parents[1] / 'scripts/notify-release-cache.sh').read_text()
        for product in ('mnscloud-phoneweb', 'mnscloud-pulse', 'mnscloud-pos', 'mnscloud-customer-portal', 'mnscloud-website'):
            self.assertIn(f'"{product}"', script)

    def test_rejects_abbreviated_commit(self):
        with self.assertRaisesRegex(SystemExit, 'full commit SHA'):
            self.payload('1234567890ab')
