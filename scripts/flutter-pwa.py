#!/usr/bin/env python3
"""Turns a Flutter web build into an MNSCloud PWA and validates it.

Flutter no longer generates a caching service worker (3.47 ships a self-unregistering stub), so
every MNSCloud web client uses the service worker of templates/pwa/ instead:

  flutter build web --release --base-href / --no-web-resources-cdn
  python3 <runtime-kit>/scripts/flutter-pwa.py generate --build-dir build/web --app phoneweb
  python3 <runtime-kit>/scripts/flutter-pwa.py validate --build-dir build/web --base-href /

generate:
  - removes the deprecated Flutter service worker registration from flutter_bootstrap.js (the
    stub file itself stays: it cleans up workers registered by older releases);
  - appends templates/pwa/register.js (registers sw.js, exposes window.mnscloudPwa);
  - writes sw.js with the app shell of this build and a revision derived from its content.

validate fails when the manifest, index.html, service worker or bootstrap break the contract
(see the runtime-kit README, section Flutter clients).
"""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATES = ROOT / 'templates' / 'pwa'
SW_MARKER = 'mnscloud-pwa-sw v1'
REGISTER_MARKER = 'mnscloud-pwa-register v1'
# Files the service worker never serves from cache: the new-version notice reads them, or they are
# the workers themselves.
NEVER_CACHE = [
    'sw.js', 'flutter_service_worker.js', 'build.json', 'update-policy.json', 'version.json',
    '.last_build_id',
]
# Loaded on demand: only the CanvasKit variant the browser uses is precached (see sw.js).
SKIP_PREFIXES = ('canvaskit/',)
SKIP_SUFFIXES = ('.map', '.symbols', '.wasm', '.mjs')
SKIP_FILES = {'assets/NOTICES'}
CANVASKIT = {
    'generic': ['canvaskit/canvaskit.js', 'canvaskit/canvaskit.wasm'],
    'chromium': ['canvaskit/chromium/canvaskit.js', 'canvaskit/chromium/canvaskit.wasm'],
}
DEFAULT_RUNTIME_ORIGINS = ['https://fonts.gstatic.com']
LOADER_SW_RE = re.compile(
    r'_flutter\.loader\.load\(\s*\{\s*serviceWorkerSettings\s*:\s*\{[^{}]*\}\s*,?\s*\}\s*\)')
LOADER_CALL = '_flutter.loader.load('
DISPLAY_MODES = {'standalone', 'fullscreen', 'minimal-ui', 'window-controls-overlay'}


def log(message):
    print(f'[mnscloud-runtime-kit/flutter-pwa] {message}')


def fail(errors):
    for error in errors:
        print(f'[mnscloud-runtime-kit/flutter-pwa] ERROR: {error}', file=sys.stderr)
    sys.exit(1)


def registers_flutter_worker(bootstrap_text):
    # The inlined loader code mentions serviceWorkerSettings itself: only the final call matters.
    index = bootstrap_text.rfind(LOADER_CALL)
    return index >= 0 and 'serviceWorkerSettings' in bootstrap_text[index:]


def shell_files(build):
    files = []
    for path in sorted(p for p in build.rglob('*') if p.is_file()):
        rel = path.relative_to(build).as_posix()
        if rel in NEVER_CACHE or rel in SKIP_FILES:
            continue
        if rel.startswith(SKIP_PREFIXES) or rel.endswith(SKIP_SUFFIXES):
            continue
        files.append(rel)
    return files


def revision(build, paths, template):
    digest = hashlib.sha256(template.encode())
    for rel in paths:
        digest.update(rel.encode() + b'\0')
        digest.update(hashlib.sha256((build / rel).read_bytes()).digest())
    return digest.hexdigest()[:16]


def generate(args):
    build = Path(args.build_dir)
    bootstrap = build / 'flutter_bootstrap.js'
    errors = []
    if not (build / 'index.html').is_file():
        errors.append(f'{build}/index.html not found: run flutter build web first')
    if not bootstrap.is_file():
        errors.append(f'{bootstrap} not found')
    if not re.match(r'^[a-z][a-z0-9-]*$', args.app):
        errors.append('--app must be a lowercase id such as phoneweb')
    if errors:
        fail(errors)

    text = bootstrap.read_text()
    if '"useLocalCanvasKit":true' not in text:
        fail(['CanvasKit comes from the Google CDN: build with --no-web-resources-cdn'])
    text = LOADER_SW_RE.sub('_flutter.loader.load()', text)
    if registers_flutter_worker(text):
        fail(['flutter_bootstrap.js still configures the Flutter service worker; use a custom '
              'web/flutter_bootstrap.js that calls _flutter.loader.load() without it'])
    if REGISTER_MARKER not in text:
        text = text.rstrip() + '\n\n' + (TEMPLATES / 'register.js').read_text()
    bootstrap.write_text(text)

    canvaskit = {name: [p for p in paths if (build / p).is_file()] for name, paths in CANVASKIT.items()}
    precache = shell_files(build)
    template = (TEMPLATES / 'sw.js').read_text()
    rev = revision(build, precache + canvaskit['generic'] + canvaskit['chromium'], template)
    origins = sorted(set(DEFAULT_RUNTIME_ORIGINS + (args.runtime_origin or [])))
    never = sorted(set(NEVER_CACHE + (args.never_cache or [])))
    values = {
        '__MNSCLOUD_PWA_APP__': args.app,
        '__MNSCLOUD_PWA_REVISION__': rev,
        '__MNSCLOUD_PWA_PRECACHE__': precache,
        '__MNSCLOUD_PWA_CANVASKIT__': canvaskit,
        '__MNSCLOUD_PWA_RUNTIME_ORIGINS__': origins,
        '__MNSCLOUD_PWA_NEVER_CACHE__': never,
    }
    for key, value in values.items():
        template = template.replace(key, json.dumps(value))
    (build / 'sw.js').write_text(template)
    size = sum((build / p).stat().st_size for p in precache) // 1024
    log(f'sw.js revision {rev}: {len(precache)} shell files ({size} KiB) + CanvasKit on install')
    return 0


def check_manifest(build, errors):
    path = build / 'manifest.json'
    if not path.is_file():
        errors.append('manifest.json not found')
        return
    try:
        manifest = json.loads(path.read_text())
    except ValueError as error:
        errors.append(f'manifest.json is not JSON: {error}')
        return
    for field in ('name', 'short_name', 'id', 'start_url', 'scope', 'theme_color',
                  'background_color'):
        if not manifest.get(field):
            errors.append(f'manifest.json: missing {field}')
    for field in ('id', 'start_url', 'scope'):
        value = str(manifest.get(field, ''))
        if value.startswith(('/', 'http:', 'https:')):
            errors.append(f'manifest.json: {field} must be relative (".") to work under any base path')
    if manifest.get('display') not in DISPLAY_MODES:
        errors.append('manifest.json: display must be standalone, fullscreen, minimal-ui or '
                      'window-controls-overlay')
    if manifest.get('prefer_related_applications') is True:
        errors.append('manifest.json: prefer_related_applications blocks installation')
    icons = manifest.get('icons') or []

    def has(size, purpose):
        return any(size in str(icon.get('sizes', '')).split() and
                   purpose in str(icon.get('purpose', 'any')).split() for icon in icons)
    for size in ('192x192', '512x512'):
        if not has(size, 'any'):
            errors.append(f'manifest.json: no {size} icon with purpose any')
    if not any('maskable' in str(icon.get('purpose', '')).split() for icon in icons):
        errors.append('manifest.json: no maskable icon')
    for icon in icons:
        if icon.get('src') and not (build / icon['src']).is_file():
            errors.append(f'manifest.json: icon {icon["src"]} not found in the build')


def check_index(build, base_href, errors):
    path = build / 'index.html'
    if not path.is_file():
        errors.append('index.html not found')
        return
    html = path.read_text()
    match = re.search(r'<base\s+href="([^"]*)"', html)
    if not match or match.group(1) != base_href:
        errors.append(f'index.html: <base href> must be "{base_href}"')
    if not re.search(r'<link[^>]+rel="manifest"', html):
        errors.append('index.html: missing <link rel="manifest">')
    if not re.search(r'<meta[^>]+name="viewport"', html):
        errors.append('index.html: missing viewport meta')
    if not re.search(r'<meta[^>]+name="theme-color"', html):
        errors.append('index.html: missing theme-color meta')


def check_worker(build, errors):
    sw = build / 'sw.js'
    if not sw.is_file():
        errors.append('sw.js not found: run flutter-pwa.py generate after the build')
        return
    text = sw.read_text()
    if SW_MARKER not in text or '__MNSCLOUD_PWA_' in text:
        errors.append('sw.js is not a rendered MNSCloud service worker')
        return
    match = re.search(r'^const PRECACHE = (\[.*\]);$', text, re.M)
    precache = json.loads(match.group(1)) if match else []
    if 'index.html' not in precache:
        errors.append('sw.js: index.html is not precached')
    for rel in precache:
        if 'api/' in rel or rel in NEVER_CACHE:
            errors.append(f'sw.js: {rel} must never be precached')
        elif not (build / rel).is_file():
            errors.append(f'sw.js: precached {rel} is missing from the build')
    bootstrap = build / 'flutter_bootstrap.js'
    boot = bootstrap.read_text() if bootstrap.is_file() else ''
    if REGISTER_MARKER not in boot:
        errors.append('flutter_bootstrap.js does not register sw.js')
    if registers_flutter_worker(boot):
        errors.append('flutter_bootstrap.js still registers the deprecated Flutter service worker')
    if '"useLocalCanvasKit":true' not in boot:
        errors.append('CanvasKit comes from the Google CDN: build with --no-web-resources-cdn')


def validate(args):
    build = Path(args.build_dir)
    errors = []
    check_manifest(build, errors)
    check_index(build, args.base_href, errors)
    check_worker(build, errors)
    if errors:
        fail(errors)
    log(f'{build}: PWA contract OK')
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    gen = sub.add_parser('generate')
    gen.add_argument('--build-dir', default='build/web')
    gen.add_argument('--app', required=True)
    gen.add_argument('--runtime-origin', action='append',
                     help='extra https origin cached on first use (fonts, map styles)')
    gen.add_argument('--never-cache', action='append', help='extra file never served from cache')
    val = sub.add_parser('validate')
    val.add_argument('--build-dir', default='build/web')
    val.add_argument('--base-href', default='/')
    args = parser.parse_args(argv)
    return generate(args) if args.command == 'generate' else validate(args)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
