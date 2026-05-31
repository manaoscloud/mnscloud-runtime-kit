#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/release-runtime-kit.sh --version X.Y.Z [--channel stable|candidate]

Maintainer helper for preparing a homologated mnscloud-runtime-kit release:
  - updates VERSION
  - updates releases/manifest.json channel metadata
  - validates shell syntax and CLI help
  - commits the release metadata
  - creates Git tag vX.Y.Z

Push with:
  git push origin main
  git push origin vX.Y.Z
  gh release create vX.Y.Z --title "mnscloud-runtime-kit vX.Y.Z" --notes-file RELEASE_NOTES.md
EOF
}

VERSION_VALUE=""
CHANNEL="stable"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION_VALUE="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage; exit 1 ;;
  esac
done

[[ "$VERSION_VALUE" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
  { printf 'ERROR: --version must be semantic, got: %s\n' "$VERSION_VALUE" >&2; exit 1; }
[[ "$CHANNEL" == "stable" || "$CHANNEL" == "candidate" ]] ||
  { printf 'ERROR: unsupported channel: %s\n' "$CHANNEL" >&2; exit 1; }

cd "$ROOT_DIR"
[[ -z "$(git status --short)" ]] ||
  { printf 'ERROR: working tree must be clean before preparing a release\n' >&2; exit 1; }

printf '%s\n' "$VERSION_VALUE" > VERSION

RELEASE_VERSION="$VERSION_VALUE" RELEASE_CHANNEL="$CHANNEL" deno run \
  --allow-read=releases/manifest.json \
  --allow-write=releases/manifest.json \
  --allow-env=RELEASE_VERSION,RELEASE_CHANNEL \
  - <<'DENO'
const path = 'releases/manifest.json';
const version = Deno.env.get('RELEASE_VERSION')!;
const channel = Deno.env.get('RELEASE_CHANNEL')!;
const manifest = JSON.parse(await Deno.readTextFile(path));
manifest.channels[channel] = {
  ...manifest.channels[channel],
  version,
  ref: `v${version}`,
  releasedAt: new Date().toISOString(),
};
await Deno.writeTextFile(path, `${JSON.stringify(manifest, null, 2)}\n`);
DENO

bash -n scripts/*.sh lib/*.sh installers/*.sh
./scripts/install-tool.sh --help >/dev/null
./scripts/doctor.sh --help >/dev/null

git add VERSION releases/manifest.json
git commit -m "Release mnscloud-runtime-kit v${VERSION_VALUE}"
git tag "v${VERSION_VALUE}"
printf 'Prepared mnscloud-runtime-kit v%s on channel %s\n' "$VERSION_VALUE" "$CHANNEL"
