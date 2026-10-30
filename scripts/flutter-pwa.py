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
(see the runtime-kit README, section Flutter clients). The build directory must be under the
current directory.
"""
import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(os.path.abspath(__file__)).parents[1]
TEMPLATES = ROOT / 'templates' / 'pwa'
SW_FILE = 'sw.js'
INDEX_FILE = 'index.html'
MANIFEST_FILE = 'manifest.json'
BOOTSTRAP_FILE = 'flutter_bootstrap.js'
SW_MARKER = 'mnscloud-pwa-sw v1'
REGISTER_MARKER = 'mnscloud-pwa-register v1'
LOCAL_CANVASKIT = '"useLocalCanvasKit":true'
CDN_CANVASKIT_ERROR = 'CanvasKit comes from the Google CDN: build with --no-web-resources-cdn'
# Files the service worker never serves from cache: the new-version notice reads them, or they are
# the workers themselves.
NEVER_CACHE = [
    SW_FILE, 'flutter_service_worker.js', 'build.json', 'update-policy.json', 'version.json',
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
LOADER_CALL = '_flutter.loader.load('
DISPLAY_MODES = {'standalone', 'fullscreen', 'minimal-ui', 'window-controls-overlay'}
REQUIRED_FIELDS = ('name', 'short_name', 'id', 'start_url', 'scope', 'theme_color',
                   'background_color')
RELATIVE_FIELDS = ('id', 'start_url', 'scope')


def log(message):
    print(f'[mnscloud-runtime-kit/flutter-pwa] {message}')


def fail(errors):
    for error in errors:
        print(f'[mnscloud-runtime-kit/flutter-pwa] ERROR: {error}', file=sys.stderr)
    sys.exit(1)


def trusted_dir(path):
    """The build directory is accepted only under the current directory (no traversal)."""
    base = os.path.abspath(os.getcwd())
    resolved = os.path.normpath(os.path.join(base, path))
    if not resolved.startswith(base + os.sep) or not os.path.isdir(resolved):
        fail([f'{path}: not a directory under the current directory'])
    return Path(resolved)


def inside(build, rel):
    """A path named by a build file (manifest icon, precache entry) must stay in the build."""
    resolved = os.path.normpath(os.path.join(build, rel))
    return Path(resolved) if resolved.startswith(str(build) + os.sep) else None


def loader_tail(text):
    index = text.rfind(LOADER_CALL)
    return index, (text[index:] if index >= 0 else '')


def registers_flutter_worker(text):
    # The inlined loader code mentions serviceWorkerSettings itself: only the final call matters.
    return 'serviceWorkerSettings' in loader_tail(text)[1]


def drop_flutter_worker(text):
    index, tail = loader_tail(text)
    if 'serviceWorkerSettings' not in tail:
        return text
    end = tail.find('});')
    if end < 0:
        return text
    return text[:index] + '_flutter.loader.load();' + tail[end + 3:]


def shell_files(build):
    files = []
    for path in sorted(p for p in build.rglob('*') if p.is_file()):
        rel = path.relative_to(build).as_posix()
        skipped = (rel in NEVER_CACHE or rel in SKIP_FILES or rel.startswith(SKIP_PREFIXES)
                   or rel.endswith(SKIP_SUFFIXES))
        if not skipped:
            files.append(rel)
    return files


def revision(build, paths, template):
    digest = hashlib.sha256(template.encode())
    for rel in paths:
        digest.update(rel.encode() + b'\0')
        digest.update(hashlib.sha256((build / rel).read_bytes()).digest())
    return digest.hexdigest()[:16]


def prepare_bootstrap(build):
    bootstrap = build / BOOTSTRAP_FILE
    if not (build / INDEX_FILE).is_file() or not bootstrap.is_file():
        fail([f'{build}: {INDEX_FILE} or {BOOTSTRAP_FILE} not found: run flutter build web first'])
    text = bootstrap.read_text()
    if LOCAL_CANVASKIT not in text:
        fail([CDN_CANVASKIT_ERROR])
    text = drop_flutter_worker(text)
    if registers_flutter_worker(text):
        fail([f'{BOOTSTRAP_FILE} still configures the Flutter service worker; use a custom '
              f'web/{BOOTSTRAP_FILE} that calls _flutter.loader.load() without it'])
    if REGISTER_MARKER not in text:
        text = text.rstrip() + '\n\n' + (TEMPLATES / 'register.js').read_text()
    bootstrap.write_text(text)


def generate(args):
    if not re.match(r'^[a-z][a-z0-9-]*$', args.app):
        fail(['--app must be a lowercase id such as phoneweb'])
    bad = [o for o in args.runtime_origin or [] if not re.match(r'^https://[a-z0-9.-]+(:\d+)?$', o)]
    if bad:
        fail([f'--runtime-origin must be an https origin: {", ".join(bad)}'])
    build = trusted_dir(args.build_dir)
    prepare_bootstrap(build)

    canvaskit = {name: [p for p in paths if (build / p).is_file()] for name, paths in CANVASKIT.items()}
    precache = shell_files(build)
    template = (TEMPLATES / SW_FILE).read_text()
    rev = revision(build, precache + canvaskit['generic'] + canvaskit['chromium'], template)
    values = {
        '__MNSCLOUD_PWA_APP__': args.app,
        '__MNSCLOUD_PWA_REVISION__': rev,
        '__MNSCLOUD_PWA_PRECACHE__': precache,
        '__MNSCLOUD_PWA_CANVASKIT__': canvaskit,
        '__MNSCLOUD_PWA_RUNTIME_ORIGINS__': sorted(set(DEFAULT_RUNTIME_ORIGINS + (args.runtime_origin or []))),
        '__MNSCLOUD_PWA_NEVER_CACHE__': sorted(set(NEVER_CACHE + (args.never_cache or []))),
    }
    for placeholder, value in values.items():
        template = template.replace(placeholder, json.dumps(value))
    (build / SW_FILE).write_text(template)
    size = sum((build / p).stat().st_size for p in precache) // 1024
    log(f'{SW_FILE} revision {rev}: {len(precache)} shell files ({size} KiB) + CanvasKit on install')
    return 0


def read_manifest(build, errors):
    path = build / MANIFEST_FILE
    if not path.is_file():
        errors.append(f'{MANIFEST_FILE} not found')
        return None
    try:
        return json.loads(path.read_text())
    except ValueError as error:
        errors.append(f'{MANIFEST_FILE} is not JSON: {error}')
        return None


def check_manifest_fields(manifest, errors):
    errors.extend(f'{MANIFEST_FILE}: missing {field}' for field in REQUIRED_FIELDS
                  if not manifest.get(field))
    errors.extend(f'{MANIFEST_FILE}: {field} must be relative (".") to work under any base path'
                  for field in RELATIVE_FIELDS
                  if str(manifest.get(field, '')).startswith(('/', 'http:', 'https:')))
    if manifest.get('display') not in DISPLAY_MODES:
        errors.append(f'{MANIFEST_FILE}: display must be standalone, fullscreen, minimal-ui or '
                      'window-controls-overlay')
    if manifest.get('prefer_related_applications') is True:
        errors.append(f'{MANIFEST_FILE}: prefer_related_applications blocks installation')


def icon_has(icons, size, purpose):
    return any(size in str(icon.get('sizes', '')).split() and
               purpose in str(icon.get('purpose', 'any')).split() for icon in icons)


def check_manifest_icons(build, manifest, errors):
    icons = manifest.get('icons') or []
    errors.extend(f'{MANIFEST_FILE}: no {size} icon with purpose any'
                  for size in ('192x192', '512x512') if not icon_has(icons, size, 'any'))
    if not any('maskable' in str(icon.get('purpose', '')).split() for icon in icons):
        errors.append(f'{MANIFEST_FILE}: no maskable icon')
    for icon in icons:
        src = icon.get('src')
        target = inside(build, src) if src else None
        if src and (target is None or not target.is_file()):
            errors.append(f'{MANIFEST_FILE}: icon {src} not found in the build')


def check_index(build, base_href, errors):
    path = build / INDEX_FILE
    if not path.is_file():
        errors.append(f'{INDEX_FILE} not found')
        return
    html = path.read_text()
    match = re.search(r'<base href="([^"]*)"', html)
    if not match or match.group(1) != base_href:
        errors.append(f'{INDEX_FILE}: <base href> must be "{base_href}"')
    for pattern, what in ((r'rel="manifest"', 'manifest link'), (r'name="viewport"', 'viewport meta'),
                          (r'name="theme-color"', 'theme-color meta')):
        if not re.search(pattern, html):
            errors.append(f'{INDEX_FILE}: missing {what}')


def check_precache(build, text, errors):
    match = re.search(r'^const PRECACHE = (\[.*\]);$', text, re.M)
    precache = json.loads(match.group(1)) if match else []
    if INDEX_FILE not in precache:
        errors.append(f'{SW_FILE}: {INDEX_FILE} is not precached')
    for rel in precache:
        target = inside(build, rel)
        if 'api/' in rel or rel in NEVER_CACHE:
            errors.append(f'{SW_FILE}: {rel} must never be precached')
        elif target is None or not target.is_file():
            errors.append(f'{SW_FILE}: precached {rel} is missing from the build')


def check_worker(build, errors):
    sw = build / SW_FILE
    if not sw.is_file():
        errors.append(f'{SW_FILE} not found: run flutter-pwa.py generate after the build')
        return
    text = sw.read_text()
    if SW_MARKER not in text or '__MNSCLOUD_PWA_' in text:
        errors.append(f'{SW_FILE} is not a rendered MNSCloud service worker')
        return
    check_precache(build, text, errors)
    bootstrap = build / BOOTSTRAP_FILE
    boot = bootstrap.read_text() if bootstrap.is_file() else ''
    if REGISTER_MARKER not in boot:
        errors.append(f'{BOOTSTRAP_FILE} does not register {SW_FILE}')
    if registers_flutter_worker(boot):
        errors.append(f'{BOOTSTRAP_FILE} still registers the deprecated Flutter service worker')
    if LOCAL_CANVASKIT not in boot:
        errors.append(CDN_CANVASKIT_ERROR)


def validate(args):
    build = trusted_dir(args.build_dir)
    errors = []
    manifest = read_manifest(build, errors)
    if manifest is not None:
        check_manifest_fields(manifest, errors)
        check_manifest_icons(build, manifest, errors)
    check_index(build, args.base_href, errors)
    check_worker(build, errors)
    if errors:
        fail(errors)
    log(f'{args.build_dir}: PWA contract OK')
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
