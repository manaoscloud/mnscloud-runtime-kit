#!/usr/bin/env bash
set -Eeuo pipefail

# Packages a built static web directory (Flutter build/web, Astro dist/, ...) as a release
# artifact and records it under channels.<channel>.artifact in releases/manifest.json.
# Intended to run as a `--validate` step of mrtk_release_prepare, after the manifest version was
# updated and before the release commit, so the artifact metadata is committed with the release.

log() { printf '[mnscloud-runtime-kit/static-artifact] %s\n' "$*"; }
die() { printf '[mnscloud-runtime-kit/static-artifact] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  scripts/package-static-artifact.sh --source-dir <dir> --name <file.tar.gz> [options]

Options:
  --manifest <path>     Release manifest to update. Default: releases/manifest.json.
  --channel <name>      Manifest channel that receives the artifact. Default: stable.
  --output-dir <dir>    Directory for the archive and its .sha256 file. Default: releases.

The archive contains the files of --source-dir at its root (no leading directory). A
<name>.sha256 file in `sha256sum` format is written next to it. Upload both with
mrtk_release_prepare --asset-glob; do not commit them.
EOF
}

SOURCE_DIR=""
NAME=""
MANIFEST="releases/manifest.json"
CHANNEL="stable"
OUTPUT_DIR="releases"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir) SOURCE_DIR="${2:-}"; shift 2 ;;
    --name) NAME="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ -n "$SOURCE_DIR" && -d "$SOURCE_DIR" ]] || die "--source-dir must be an existing directory"
[[ -f "${SOURCE_DIR}/index.html" ]] || die "${SOURCE_DIR}/index.html not found; is this a static web build?"
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*[.]tar[.]gz$ ]] || die "--name must be a plain *.tar.gz file name"
[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"
[[ "$CHANNEL" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid channel: $CHANNEL"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

install -d -m 0755 "$OUTPUT_DIR"
archive="${OUTPUT_DIR}/${NAME}"
rm -f "$archive" "${archive}.sha256"

# Reproducible-ish archive: stable ordering and ownership, mtime from the release commit.
mtime="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || date +%s)}"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@${mtime}" \
  -C "$SOURCE_DIR" -czf "$archive" .

sha256="$(sha256sum "$archive" | awk '{print $1}')"
size="$(stat -c %s "$archive")"
printf '%s  %s\n' "$sha256" "$NAME" > "${archive}.sha256"

python3 - "$MANIFEST" "$CHANNEL" "$NAME" "$sha256" "$size" <<'PY'
import json
import sys

manifest_path, channel, name, sha256, size = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
entry = manifest.setdefault("channels", {}).setdefault(channel, {})
entry["artifact"] = {
    "name": name,
    "sha256": sha256,
    "sizeBytes": int(size),
    "contentType": "application/gzip",
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(manifest, indent=2) + "\n")
PY

log "packaged ${archive} (${size} bytes, sha256 ${sha256})"
