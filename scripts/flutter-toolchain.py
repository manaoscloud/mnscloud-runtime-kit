#!/usr/bin/env python3
"""Single source of the Flutter toolchain used by every MNSCloud Flutter client.

toolchains/flutter.json pins the Flutter stable release that CI and release jobs install. The
weekly flutter-toolchain-bump workflow moves it to the newest stable after validating the clients,
so "always the latest Flutter" stays reproducible: a rebuild of a tag uses a known toolchain.

Usage:
  flutter-toolchain.py get [flutter|dart|channel]    print a field of the pinned toolchain
  flutter-toolchain.py latest [--channel stable]     print the newest release as JSON
  flutter-toolchain.py set <flutter> <dart> <date>   rewrite the pinned toolchain
  flutter-toolchain.py compare                       exit 10 when a newer stable exists
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLCHAIN = ROOT / 'toolchains' / 'flutter.json'
RELEASES_URL = 'https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json'
VERSION_RE = re.compile(r'^\d+\.\d+\.\d+$')


def fail(message):
    print(f'[mnscloud-runtime-kit/flutter-toolchain] ERROR: {message}', file=sys.stderr)
    sys.exit(1)


def load(path=TOOLCHAIN):
    data = json.loads(Path(path).read_text())
    for field in ('channel', 'flutter', 'dart'):
        if not isinstance(data.get(field), str) or not data[field]:
            fail(f'{path}: missing field {field}')
    if not VERSION_RE.match(data['flutter']) or not VERSION_RE.match(data['dart']):
        fail(f'{path}: flutter and dart must be x.y.z')
    return data


def version_key(version):
    return tuple(int(part) for part in version.split('.'))


def latest(channel='stable', source=None):
    if source:
        payload = json.loads(Path(source).read_text())
    else:
        with urllib.request.urlopen(RELEASES_URL, timeout=30) as response:
            payload = json.load(response)
    current = payload['current_release'][channel]
    for release in payload['releases']:
        if release['hash'] == current and release['channel'] == channel:
            return {
                'channel': channel,
                'flutter': release['version'],
                'dart': release.get('dart_sdk_version', '').split(' ')[0],
                'releasedAt': release['release_date'][:10],
            }
    fail(f'current {channel} release {current} not found in the release list')


def write(flutter, dart, released_at, path=TOOLCHAIN):
    if not VERSION_RE.match(flutter) or not VERSION_RE.match(dart):
        fail('flutter and dart must be x.y.z')
    if not re.match(r'^\d{4}-\d{2}-\d{2}$', released_at):
        fail('date must be YYYY-MM-DD')
    data = load(path)
    data.update({'flutter': flutter, 'dart': dart, 'releasedAt': released_at})
    Path(path).write_text(json.dumps(data, indent=2) + '\n')


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__)
        return 0
    command, args = argv[0], argv[1:]
    if command == 'get':
        field = args[0] if args else 'flutter'
        print(load()[field])
    elif command == 'latest':
        channel = args[1] if len(args) > 1 and args[0] == '--channel' else 'stable'
        print(json.dumps(latest(channel)))
    elif command == 'set':
        if len(args) != 3:
            fail('set needs <flutter> <dart> <YYYY-MM-DD>')
        write(*args)
    elif command == 'compare':
        pinned = load()
        newest = latest(pinned['channel'], args[0] if args else None)
        print(json.dumps({'pinned': pinned['flutter'], 'latest': newest}))
        return 10 if version_key(newest['flutter']) > version_key(pinned['flutter']) else 0
    else:
        fail(f'unknown command: {command}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
