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


class TagOnlyReleaseTest(unittest.TestCase):
    """Protected main: the release pushes only its tag and increments from the latest tag."""

    def test_publish_skips_main_push_when_tag_only(self):
        script = (Path(__file__).resolve().parents[1] / 'lib/release.sh').read_text()
        guarded = script.split('if [[ "${MRTK_RELEASE_TAG_ONLY:-0}" != "1" ]]; then', 1)
        self.assertEqual(len(guarded), 2)
        self.assertTrue(guarded[1].lstrip().startswith('git push origin main'))
        self.assertIn('git push origin "$tag"', guarded[1])

    def test_workflow_passes_tag_only_and_reads_latest_tag(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/auto-release.yml').read_text()
        self.assertIn('tag_only:', workflow)
        self.assertIn("MRTK_RELEASE_TAG_ONLY: ${{ inputs.tag_only && '1' || '0' }}", workflow)
        self.assertIn("git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname", workflow)
