#!/usr/bin/env python3
"""Single source of the Flutter toolchain used by every MNSCloud Flutter client.

toolchains/flutter.json pins the Flutter stable release that CI and release jobs install. The
weekly flutter-toolchain-bump workflow moves it to the newest stable after validating the clients,
so "always the latest Flutter" stays reproducible: a rebuild of a tag uses a known toolchain.

Usage:
  flutter-toolchain.py get [flutter|dart|channel]    print a field of the pinned toolchain
  flutter-toolchain.py latest                        print the newest stable as JSON
  flutter-toolchain.py set <flutter> <dart> <date>   rewrite the pinned toolchain
  flutter-toolchain.py compare [releases.json]       exit 10 when a newer stable exists; the
                                                     optional release list (tests) must be a file
                                                     under the current directory
"""
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLCHAIN = ROOT / 'toolchains' / 'flutter.json'
RELEASES_URL = 'https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json'
VERSION_RE = re.compile(r'^\d+\.\d+\.\d+$')
DATE_RE = re.compile(r'^\d{4}-\d{2}-\d{2}$')
FIELDS = ('channel', 'flutter', 'dart')


def fail(message):
    print(f'[mnscloud-runtime-kit/flutter-toolchain] ERROR: {message}', file=sys.stderr)
    sys.exit(1)


def trusted_file(path):
    """A file argument is accepted only inside the current directory (no traversal)."""
    base = os.path.realpath(os.getcwd())
    resolved = os.path.realpath(path)
    if not resolved.startswith(base + os.sep) or not os.path.isfile(resolved):
        fail(f'{path}: not a file under the current directory')
    return Path(resolved)


def load():
    data = json.loads(TOOLCHAIN.read_text())
    for field in FIELDS:
        if not isinstance(data.get(field), str) or not data[field]:
            fail(f'{TOOLCHAIN}: missing field {field}')
    if not VERSION_RE.match(data['flutter']) or not VERSION_RE.match(data['dart']):
        fail(f'{TOOLCHAIN}: flutter and dart must be x.y.z')
    return data


def version_key(version):
    return tuple(int(part) for part in version.split('.'))


def release_list(source=None):
    if source:
        return json.loads(trusted_file(source).read_text())
    with urllib.request.urlopen(RELEASES_URL, timeout=30) as response:
        return json.load(response)


def latest(channel='stable', source=None):
    payload = release_list(source)
    current = payload['current_release'][channel]
    for release in payload['releases']:
        if release['hash'] == current and release['channel'] == channel:
            return {
                'channel': channel,
                'flutter': release['version'],
                'dart': release.get('dart_sdk_version', '').split(' ')[0],
                'releasedAt': release['release_date'][:10],
            }
    return fail(f'current {channel} release {current} not found in the release list')


def command_get(args):
    field = args[0] if args else 'flutter'
    if field not in FIELDS:
        fail(f'unknown field: {field}')
    print(load()[field])
    return 0


def command_latest(_args):
    print(json.dumps(latest(load()['channel'])))
    return 0


def command_set(args):
    if len(args) != 3:
        fail('set needs <flutter> <dart> <YYYY-MM-DD>')
    flutter, dart, released_at = args
    if not VERSION_RE.match(flutter) or not VERSION_RE.match(dart) or not DATE_RE.match(released_at):
        fail('set needs x.y.z versions and a YYYY-MM-DD date')
    data = load()
    data.update({'flutter': flutter, 'dart': dart, 'releasedAt': released_at})
    TOOLCHAIN.write_text(json.dumps(data, indent=2) + '\n')
    return 0


def command_compare(args):
    pinned = load()
    newest = latest(pinned['channel'], args[0] if args else None)
    print(json.dumps({'pinned': pinned['flutter'], 'latest': newest}))
    return 10 if version_key(newest['flutter']) > version_key(pinned['flutter']) else 0


COMMANDS = {'get': command_get, 'latest': command_latest, 'set': command_set,
            'compare': command_compare}


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__)
        return 0
    command = COMMANDS.get(argv[0])
    if command is None:
        fail(f'unknown command: {argv[0]}')
    return command(argv[1:])


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
