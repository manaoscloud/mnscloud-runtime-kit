"""FA5: a private runtime release uploads a git bundle of its tag before the catalog entry."""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/notify-release-cache.sh'

FAKE_CURL = """#!/usr/bin/env bash
data=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data) data="${2#@}"; shift 2 ;;
    -H|-X) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
n=$(ls "$CAPTURE" | wc -l)
cp "$data" "$CAPTURE/$n-$(basename "$url").json"
echo '{"status":"success"}'
"""


def git(cwd, *args):
    subprocess.run(['git', *args], cwd=cwd, check=True, capture_output=True, text=True,
                   env={**os.environ, 'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@example.invalid',
                        'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@example.invalid'})


class ReleasePackageTest(unittest.TestCase):
    def run_release(self, product):
        folder = tempfile.mkdtemp()
        root = Path(folder)
        repo, capture, bin_dir = root / 'repo', root / 'capture', root / 'bin'
        for path in (repo / 'releases', capture, bin_dir):
            path.mkdir(parents=True)
        (repo / 'releases/manifest.json').write_text(json.dumps({'product': product, 'channels': {'stable': {}}}))
        git(repo, 'init', '-q')
        git(repo, 'add', '.')
        git(repo, 'commit', '-q', '-m', 'release')
        git(repo, 'tag', 'v0.1.9')
        curl = bin_dir / 'curl'
        curl.write_text(FAKE_CURL)
        curl.chmod(0o755)
        env = {**os.environ, 'PATH': f'{bin_dir}:{os.environ["PATH"]}', 'CAPTURE': str(capture),
               'MNSCLOUD_RELEASE_SYNC_URL': 'https://dev.example.invalid',
               'MNSCLOUD_RELEASE_SYNC_TOKEN': 'test-token', 'GITHUB_REPOSITORY': f'manaoscloud/{product}'}
        result = subprocess.run(['bash', str(SCRIPT), '--version', '0.1.9'], cwd=repo, env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return root, sorted(capture.iterdir())

    def test_private_runtime_uploads_its_bundle_before_publishing(self):
        root, calls = self.run_release('mnscloud-dns')
        self.assertEqual([path.name.split('-', 1)[1] for path in calls], ['packages.json', 'publish.json'])
        package = json.loads(calls[0].read_text())
        data = base64.b64decode(package['contentBase64'])
        self.assertEqual((package['product'], package['version'], package['contentType']),
                         ('mnscloud-dns', '0.1.9', 'application/x-git-bundle'))
        self.assertEqual(package['sha256'], hashlib.sha256(data).hexdigest())
        bundle = root / 'dns.bundle'
        bundle.write_bytes(data)
        clone = root / 'clone'
        git(root, 'clone', '-q', str(bundle), str(clone))
        git(clone, 'checkout', '-q', '--detach', 'v0.1.9')
        self.assertTrue((clone / 'releases/manifest.json').exists())

    def test_public_products_upload_no_bundle(self):
        _, calls = self.run_release('mnscloud-access-gateway')
        self.assertEqual([path.name.split('-', 1)[1] for path in calls], ['publish.json'])


if __name__ == '__main__':
    unittest.main()
