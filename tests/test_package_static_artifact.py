"""Contract for scripts/package-static-artifact.sh (static web release artifacts)."""
from pathlib import Path
import hashlib
import json
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts' / 'package-static-artifact.sh'


class PackageStaticArtifactTest(unittest.TestCase):
    def run_script(self, folder, *args):
        return subprocess.run(
            ['bash', str(SCRIPT), *args], cwd=folder, capture_output=True, text=True,
            timeout=30, env={'PATH': '/usr/bin:/bin', 'SOURCE_DATE_EPOCH': '1700000000'})

    def make_workspace(self, folder):
        build = Path(folder) / 'build' / 'web'
        (build / 'assets').mkdir(parents=True)
        (build / 'index.html').write_text('<base href="/">')
        (build / 'assets' / 'app.js').write_text('console.log(1)')
        releases = Path(folder) / 'releases'
        releases.mkdir()
        (releases / 'manifest.json').write_text(json.dumps({
            'product': 'demo', 'channels': {'stable': {'version': '1.2.3', 'ref': 'v1.2.3'}}}))

    def test_packages_build_and_records_manifest_artifact(self):
        with tempfile.TemporaryDirectory() as folder:
            self.make_workspace(folder)
            result = self.run_script(
                folder, '--source-dir', 'build/web', '--name', 'demo-web-v1.2.3.tar.gz')
            self.assertEqual(result.returncode, 0, result.stderr)

            archive = Path(folder) / 'releases' / 'demo-web-v1.2.3.tar.gz'
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            sidecar = (Path(folder) / 'releases' / 'demo-web-v1.2.3.tar.gz.sha256').read_text()
            self.assertEqual(sidecar, f'{digest}  demo-web-v1.2.3.tar.gz\n')

            with tarfile.open(archive) as handle:
                names = sorted(name.lstrip('./') for name in handle.getnames())
            self.assertIn('index.html', names)
            self.assertIn('assets/app.js', names)

            manifest = json.loads((Path(folder) / 'releases' / 'manifest.json').read_text())
            stable = manifest['channels']['stable']
            self.assertEqual(stable['version'], '1.2.3')
            self.assertEqual(stable['artifact'], {
                'name': 'demo-web-v1.2.3.tar.gz', 'sha256': digest,
                'sizeBytes': archive.stat().st_size, 'contentType': 'application/gzip'})

    def test_rejects_directory_without_index(self):
        with tempfile.TemporaryDirectory() as folder:
            self.make_workspace(folder)
            (Path(folder) / 'build' / 'web' / 'index.html').unlink()
            result = self.run_script(
                folder, '--source-dir', 'build/web', '--name', 'demo-web-v1.2.3.tar.gz')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('index.html not found', result.stderr)

    def test_rejects_path_like_name(self):
        with tempfile.TemporaryDirectory() as folder:
            self.make_workspace(folder)
            result = self.run_script(
                folder, '--source-dir', 'build/web', '--name', '../evil.tar.gz')
            self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
