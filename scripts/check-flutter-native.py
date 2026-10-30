#!/usr/bin/env python3
"""Checks the native platform configuration of an MNSCloud Flutter client before it is built.

The Flutter templates put INTERNET only in the debug/profile Android manifests and no network
entitlement in the macOS release sandbox, so a release build can compile and still never reach the
API. This check reads the source configuration (no build needed) and fails on:

  - android: android.permission.INTERNET (plus --android-permission ...) missing from
    android/app/src/main/AndroidManifest.xml;
  - macos: com.apple.security.network.client (plus --macos-entitlement ...) missing from
    DebugProfile.entitlements or Release.entitlements; MACOSX_DEPLOYMENT_TARGET below --min-macos;
  - ios: --ios-plist-key ... missing from ios/Runner/Info.plist; IPHONEOS_DEPLOYMENT_TARGET below
    --min-ios.

Only platforms whose folder exists are checked. Usage, from the repository root:
  check-flutter-native.py --android-permission RECORD_AUDIO --ios-plist-key NSMicrophoneUsageDescription
"""
import argparse
import os
import re
import sys
from pathlib import Path

# Flutter 3.47 minimums (Xcode 27 support); raise together with toolchains/flutter.json.
DEFAULT_MIN_IOS = '15.0'
DEFAULT_MIN_MACOS = '12.0'


def confined_root(path):
    """The project root is accepted only at or under the current directory (no traversal)."""
    base = os.path.abspath(os.getcwd())
    resolved = os.path.normpath(os.path.join(base, path))
    if resolved != base and not resolved.startswith(base + os.sep):
        print(f'[mnscloud-runtime-kit/flutter-native] ERROR: {path}: outside the current directory',
              file=sys.stderr)
        sys.exit(1)
    return Path(resolved)


def version_tuple(value):
    return tuple(int(part) for part in value.split('.'))


def check_android(root, permissions, errors):
    manifest = root / 'android/app/src/main/AndroidManifest.xml'
    if not manifest.is_file():
        errors.append(f'{manifest} not found')
        return
    declared = set(re.findall(r'android:name="android\.permission\.([A-Z_]+)"', manifest.read_text()))
    for permission in ['INTERNET', *permissions]:
        if permission not in declared:
            errors.append(f'{manifest}: android.permission.{permission} missing (release builds '
                          'use only the main manifest)')


def check_macos(root, entitlements, minimum, errors):
    for name in ('DebugProfile.entitlements', 'Release.entitlements'):
        path = root / 'macos/Runner' / name
        if not path.is_file():
            errors.append(f'{path} not found')
            continue
        text = path.read_text()
        for entitlement in ['com.apple.security.network.client', *entitlements]:
            if not re.search(rf'<key>{re.escape(entitlement)}</key>\s*<true/>', text):
                errors.append(f'{path}: {entitlement} missing or not true')
    project = root / 'macos/Runner.xcodeproj/project.pbxproj'
    if project.is_file():
        for found in set(re.findall(r'MACOSX_DEPLOYMENT_TARGET = ([0-9.]+);', project.read_text())):
            if version_tuple(found) < version_tuple(minimum):
                errors.append(f'{project}: MACOSX_DEPLOYMENT_TARGET {found} < {minimum}')


def check_ios(root, entries, minimum, errors):
    plist = root / 'ios/Runner/Info.plist'
    if not plist.is_file():
        errors.append(f'{plist} not found')
        return
    text = plist.read_text()
    for entry in entries:
        if f'<key>{entry}</key>' not in text:
            errors.append(f'{plist}: {entry} missing')
    project = root / 'ios/Runner.xcodeproj/project.pbxproj'
    if project.is_file():
        for found in set(re.findall(r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);', project.read_text())):
            if version_tuple(found) < version_tuple(minimum):
                errors.append(f'{project}: IPHONEOS_DEPLOYMENT_TARGET {found} < {minimum}')


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--root', default='.')
    parser.add_argument('--android-permission', action='append', default=[],
                        help='extra permission without the android.permission. prefix')
    parser.add_argument('--macos-entitlement', action='append', default=[])
    parser.add_argument('--ios-plist-key', dest='ios_plist_entries', action='append', default=[])
    parser.add_argument('--min-ios', default=DEFAULT_MIN_IOS)
    parser.add_argument('--min-macos', default=DEFAULT_MIN_MACOS)
    args = parser.parse_args(argv)

    root = confined_root(args.root)
    errors = []
    checked = []
    if (root / 'android').is_dir():
        checked.append('android')
        check_android(root, args.android_permission, errors)
    if (root / 'macos').is_dir():
        checked.append('macos')
        check_macos(root, args.macos_entitlement, args.min_macos, errors)
    if (root / 'ios').is_dir():
        checked.append('ios')
        check_ios(root, args.ios_plist_entries, args.min_ios, errors)
    for error in errors:
        print(f'[mnscloud-runtime-kit/flutter-native] ERROR: {error}', file=sys.stderr)
    if errors:
        return 1
    print(f'[mnscloud-runtime-kit/flutter-native] OK: {", ".join(checked) or "no native platform"}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
