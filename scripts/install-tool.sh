#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<EOF
Usage: scripts/install-tool.sh --tool <nginx|flutter|mariadb|deno|nodejs|docker>
EOF
}

TOOL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool) TOOL="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage; exit 1 ;;
  esac
done

case "$TOOL" in
  nginx|flutter|mariadb|deno|nodejs|docker)
    exec "${ROOT_DIR}/installers/${TOOL}.sh"
    ;;
  "")
    printf 'ERROR: --tool is required\n' >&2
    usage
    exit 1
    ;;
  *)
    printf 'ERROR: unsupported tool: %s\n' "$TOOL" >&2
    usage
    exit 1
    ;;
esac
