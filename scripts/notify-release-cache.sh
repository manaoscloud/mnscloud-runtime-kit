#!/usr/bin/env bash
# Publish one released version of the current repository to the MNSCloud runtime release cache
# (DEV registry; production is filled by the production promotion). Shared by the Auto Release
# workflow (right after a release) and the Sync release cache workflow (existing releases).
# Usage: scripts/notify-release-cache.sh --version <x.y.z>   (run at the repository root, tag fetched)
set -euo pipefail

RELEASE_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) RELEASE_VERSION="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$RELEASE_VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || { echo "--version x.y.z is required" >&2; exit 2; }
export RELEASE_VERSION

if [ -z "${MNSCLOUD_RELEASE_SYNC_URL:-}" ] || [ -z "${MNSCLOUD_RELEASE_SYNC_TOKEN:-}" ]; then
  echo "MNSCLOUD_RELEASE_SYNC_URL or MNSCLOUD_RELEASE_SYNC_TOKEN is not configured; release cache notification skipped."
  exit 0
fi

payload="$(mktemp)"
trap 'rm -f "$payload"' EXIT
set +e
python3 - > "$payload" <<'PY'
import json
import os
import re
import subprocess

version = os.environ["RELEASE_VERSION"]
ref = f"v{version}"
with open("releases/manifest.json", encoding="utf-8") as handle:
    manifest = json.load(handle)
product = manifest.get("product")
supported_products = {
    "mnscloud-agent",
    "mnscloud-api",
    "mnscloud-app",
    "mnscloud-kamailio-softswitch",
    "mnscloud-nginx",
    "mnscloud-openvault",
    "mnscloud-rabbitmq",
    "mnscloud-workers",
    "mnscloud-authentication",
    "mnscloud-freeswitch",
    "mnscloud-asterisk",
    "mnscloud-opensips-sbc",
    "mnscloud-kamailio-webrtc",
    "mnscloud-turn",
    "mnscloud-media",
    "mnscloud-webapps",
    # Web clients installed as apps by mnscloud-webapps (versioned products of their own).
    "mnscloud-phoneweb",
    "mnscloud-pulse",
    "mnscloud-pos",
    "mnscloud-customer-portal",
    "mnscloud-website",
}
if product not in supported_products:
    raise SystemExit(78)
channel = "stable"
stable = manifest.get("channels", {}).get(channel, {})
released_at = stable.get("releasedAt")
artifact = stable.get("artifact") or {}
artifact_name = artifact.get("name")
artifact_url = None
if artifact_name:
    repository = os.environ["GITHUB_REPOSITORY"]
    artifact_url = f"https://github.com/{repository}/releases/download/{ref}/{artifact_name}"
build_ref = subprocess.check_output(
    ["git", "rev-list", "-n", "1", ref],
    text=True,
).strip()
if not re.fullmatch(r"[a-f0-9]{40}", build_ref):
    raise SystemExit("Release tag did not resolve to a full commit SHA")
print(json.dumps({
    "product": product,
    "channel": channel,
    "version": version,
    "ref": ref,
    "buildRef": build_ref,
    "buildDate": released_at,
    "releasedAt": released_at,
    "notes": f"Synced from GitHub Actions release {ref}.",
    "artifactName": artifact_name,
    "artifactUrl": artifact_url,
    "artifactSha256": artifact.get("sha256"),
    "artifactSizeBytes": artifact.get("sizeBytes"),
    "artifactContentType": artifact.get("contentType"),
}))
if os.environ.get("GITHUB_OUTPUT"):
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"product={product}\n")
        output.write(f"version={version}\n")
        output.write(f"ref={ref}\n")
PY
payload_status="$?"
set -e
if [ "$payload_status" -eq 78 ]; then
  echo "Product is not managed by the control-plane runtime release cache; notification skipped."
  exit 0
fi
if [ "$payload_status" -ne 0 ]; then
  exit "$payload_status"
fi
base_url="${MNSCLOUD_RELEASE_SYNC_URL%/}"
if [[ "$base_url" == */api/v1 ]]; then
  endpoint="${base_url}/runtime/releases/publish"
else
  endpoint="${base_url}/api/v1/runtime/releases/publish"
fi
curl -fsS -X POST \
  -H "Authorization: Bearer ${MNSCLOUD_RELEASE_SYNC_TOKEN}" \
  -H "Content-Type: application/json" \
  --data @"$payload" \
  "$endpoint"
echo
