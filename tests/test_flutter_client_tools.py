"""Contract for the Flutter client tools: toolchain pin, PWA service worker and native checks."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOLCHAIN = ROOT / 'scripts' / 'flutter-toolchain.py'
PWA = ROOT / 'scripts' / 'flutter-pwa.py'
NATIVE = ROOT / 'scripts' / 'check-flutter-native.py'

BOOTSTRAP = (
    '(()=>{var n={serviceWorkerSettings:1};_flutter={loader:{load(){}}}})();\n'
    'if (!window._flutter) { window._flutter = {}; }\n'
    '_flutter.buildConfig = {"engineRevision":"x","builds":[],"useLocalCanvasKit":true};\n\n'
    '_flutter.loader.load({\n  serviceWorkerSettings: {\n'
    '    serviceWorkerVersion: "1" /* Flutter\'s service worker is deprecated. */\n  }\n});\n')
MANIFEST = {
    'name': 'Demo App', 'short_name': 'Demo', 'id': '.', 'start_url': '.', 'scope': '.',
    'display': 'standalone', 'theme_color': '#000000', 'background_color': '#ffffff',
    'icons': [
        {'src': 'icons/Icon-192.png', 'sizes': '192x192', 'type': 'image/png'},
        {'src': 'icons/Icon-512.png', 'sizes': '512x512', 'type': 'image/png'},
        {'src': 'icons/Icon-maskable-512.png', 'sizes': '512x512', 'purpose': 'maskable'},
    ],
}
INDEX = ('<!DOCTYPE html><html><head><base href="/"><meta name="viewport" content="width=device-width">'
         '<meta name="theme-color" content="#000"><link rel="manifest" href="manifest.json"></head>'
         '<body><script src="flutter_bootstrap.js" async></script></body></html>')


def run(script, *args, cwd=None):
    return subprocess.run(['python3', str(script), *args], cwd=cwd, capture_output=True, text=True,
                          timeout=60)


def make_build(folder, manifest=None, bootstrap=BOOTSTRAP):
    build = Path(folder) / 'build' / 'web'
    for rel in ('icons', 'assets/fonts', 'canvaskit/chromium', 'canvaskit/skwasm'):
        (build / rel).mkdir(parents=True, exist_ok=True)
    (build / 'index.html').write_text(INDEX)
    (build / 'flutter_bootstrap.js').write_text(bootstrap)
    (build / 'flutter.js').write_text('// loader')
    (build / 'main.dart.js').write_text('// app')
    (build / 'manifest.json').write_text(json.dumps(manifest or MANIFEST))
    (build / 'version.json').write_text('{}')
    (build / 'update-policy.json').write_text('{"minimumVersion": null}')
    (build / 'flutter_service_worker.js').write_text('self.registration.unregister();')
    (build / 'assets' / 'NOTICES').write_text('licenses')
    (build / 'assets' / 'fonts' / 'MaterialIcons-Regular.otf').write_bytes(b'font')
    for icon in ('Icon-192.png', 'Icon-512.png', 'Icon-maskable-512.png'):
        (build / 'icons' / icon).write_bytes(b'png')
    for rel in ('canvaskit/canvaskit.js', 'canvaskit/canvaskit.wasm', 'canvaskit/chromium/canvaskit.js',
                'canvaskit/chromium/canvaskit.wasm', 'canvaskit/skwasm.wasm'):
        (build / rel).write_bytes(b'ck')
    return build


class FlutterToolchainTest(unittest.TestCase):
    def test_pinned_toolchain_is_valid(self):
        result = run(TOOLCHAIN, 'get', 'flutter')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout.strip(), r'^\d+\.\d+\.\d+$')

    def test_compare_detects_newer_stable(self):
        pinned = json.loads((ROOT / 'toolchains' / 'flutter.json').read_text())['flutter']
        major, minor, patch = (int(p) for p in pinned.split('.'))
        with tempfile.TemporaryDirectory() as folder:
            releases = Path(folder) / 'releases.json'

            def write(version):
                releases.write_text(json.dumps({
                    'current_release': {'stable': 'h1'},
                    'releases': [{'hash': 'h1', 'channel': 'stable', 'version': version,
                                  'dart_sdk_version': '9.9.9 (build 1)',
                                  'release_date': '2030-01-02T03:04:05Z'}]}))
            write(f'{major}.{minor}.{patch + 1}')
            newer = run(TOOLCHAIN, 'compare', 'releases.json', cwd=folder)
            self.assertEqual(newer.returncode, 10, newer.stderr)
            self.assertEqual(json.loads(newer.stdout)['latest']['dart'], '9.9.9')
            write(pinned)
            self.assertEqual(run(TOOLCHAIN, 'compare', 'releases.json', cwd=folder).returncode, 0)

    def test_release_list_outside_the_directory_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            result = run(TOOLCHAIN, 'compare', '../../etc/passwd', cwd=folder)
            self.assertEqual(result.returncode, 1)
            self.assertIn('not a file under the current directory', result.stderr)


class FlutterPwaTest(unittest.TestCase):
    def test_raw_flutter_build_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            build = make_build(folder)
            result = run(PWA, 'validate', '--build-dir', 'build/web', cwd=folder)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('sw.js not found', result.stderr)

    def test_generate_produces_a_valid_app_shell_worker(self):
        with tempfile.TemporaryDirectory() as folder:
            build = make_build(folder)
            result = run(PWA, 'generate', '--build-dir', 'build/web', '--app', 'demo', cwd=folder)
            self.assertEqual(result.returncode, 0, result.stderr)
            validated = run(PWA, 'validate', '--build-dir', 'build/web', cwd=folder)
            self.assertEqual(validated.returncode, 0, validated.stderr)

            boot = (build / 'flutter_bootstrap.js').read_text()
            self.assertTrue(boot.rstrip().endswith('})();'))
            self.assertIn('_flutter.loader.load()', boot)
            self.assertEqual(boot.count('mnscloud-pwa-register v1'), 1)
            for api in ('applyUpdate', 'persistStorage', 'installState', 'promptInstall',
                        'onInstallChange', 'beforeinstallprompt'):
                self.assertIn(api, boot)
            self.assertTrue((build / 'flutter_service_worker.js').exists(), 'stub kept for cleanup')

            sw = (build / 'sw.js').read_text()
            self.assertNotIn('__MNSCLOUD_PWA_', sw)
            precache = json.loads(sw.split('const PRECACHE = ', 1)[1].split(';\n', 1)[0])
            self.assertIn('index.html', precache)
            for excluded in ('version.json', 'update-policy.json', 'flutter_service_worker.js',
                             'assets/NOTICES', 'canvaskit/skwasm.wasm', 'canvaskit/canvaskit.wasm'):
                self.assertNotIn(excluded, precache)
            self.assertIn('canvaskit/chromium/canvaskit.wasm', sw)

            again = run(PWA, 'generate', '--build-dir', 'build/web', '--app', 'demo', cwd=folder)
            self.assertEqual(again.returncode, 0, again.stderr)
            self.assertEqual((build / 'flutter_bootstrap.js').read_text().count('mnscloud-pwa-register v1'), 1)

    def test_revision_changes_with_content(self):
        with tempfile.TemporaryDirectory() as folder:
            build = make_build(folder)
            run(PWA, 'generate', '--build-dir', 'build/web', '--app', 'demo', cwd=folder)
            first = (build / 'sw.js').read_text()
            (build / 'main.dart.js').write_text('// app v2')
            run(PWA, 'generate', '--build-dir', 'build/web', '--app', 'demo', cwd=folder)
            self.assertNotEqual(first, (build / 'sw.js').read_text())

    def test_cdn_canvaskit_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            build = make_build(folder, bootstrap=BOOTSTRAP.replace('"useLocalCanvasKit":true', '"x":1'))
            result = run(PWA, 'generate', '--build-dir', 'build/web', '--app', 'demo', cwd=folder)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('--no-web-resources-cdn', result.stderr)

    def test_manifest_contract(self):
        manifest = dict(MANIFEST, scope='/demo/', display='browser')
        manifest.pop('id')
        with tempfile.TemporaryDirectory() as folder:
            build = make_build(folder, manifest=manifest)
            run(PWA, 'generate', '--build-dir', 'build/web', '--app', 'demo', cwd=folder)
            result = run(PWA, 'validate', '--build-dir', 'build/web', cwd=folder)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('missing id', result.stderr)
            self.assertIn('scope must be relative', result.stderr)
            self.assertIn('display must be', result.stderr)

    def test_build_dir_outside_the_directory_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            make_build(folder)
            result = run(PWA, 'validate', '--build-dir', '/etc', cwd=folder)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('not a directory under the current directory', result.stderr)

    @unittest.skipUnless(shutil.which('node'), 'node not installed')
    def test_generated_javascript_parses(self):
        with tempfile.TemporaryDirectory() as folder:
            build = make_build(folder)
            run(PWA, 'generate', '--build-dir', 'build/web', '--app', 'demo', cwd=folder)
            for name in ('sw.js', 'flutter_bootstrap.js'):
                result = subprocess.run(['node', '--check', str(build / name)], capture_output=True,
                                        text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)


class FlutterNativeTest(unittest.TestCase):
    def make_project(self, folder, internet=True, network=True, ios_target='15.0'):
        root = Path(folder)
        manifest = root / 'android/app/src/main/AndroidManifest.xml'
        manifest.parent.mkdir(parents=True)
        permission = '<uses-permission android:name="android.permission.INTERNET"/>' if internet else ''
        manifest.write_text(f'<manifest>{permission}<application/></manifest>')
        runner = root / 'macos/Runner'
        runner.mkdir(parents=True)
        entry = '<key>com.apple.security.network.client</key>\n<true/>' if network else ''
        for name in ('DebugProfile.entitlements', 'Release.entitlements'):
            (runner / name).write_text(f'<plist><dict>{entry}</dict></plist>')
        ios = root / 'ios/Runner.xcodeproj'
        ios.mkdir(parents=True)
        (ios / 'project.pbxproj').write_text(f'IPHONEOS_DEPLOYMENT_TARGET = {ios_target};')
        (root / 'ios/Runner/Info.plist').parent.mkdir(parents=True)
        (root / 'ios/Runner/Info.plist').write_text('<key>NSCameraUsageDescription</key>')
        return root

    def test_complete_project_passes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = self.make_project(folder)
            result = run(NATIVE, '--ios-plist-key', 'NSCameraUsageDescription', cwd=root)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_template_gaps_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            root = self.make_project(folder, internet=False, network=False, ios_target='13.0')
            result = run(NATIVE, '--android-permission', 'RECORD_AUDIO',
                         '--ios-plist-key', 'NSMicrophoneUsageDescription', cwd=root)
            self.assertNotEqual(result.returncode, 0)
            for expected in ('android.permission.INTERNET', 'android.permission.RECORD_AUDIO',
                             'network.client', 'IPHONEOS_DEPLOYMENT_TARGET 13.0',
                             'NSMicrophoneUsageDescription'):
                self.assertIn(expected, result.stderr)


if __name__ == '__main__':
    unittest.main()
