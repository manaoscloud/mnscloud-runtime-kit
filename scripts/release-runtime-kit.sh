#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/release.sh
source "${ROOT_DIR}/lib/release.sh"

mrtk_release_prepare \
  --product mnscloud-runtime-kit \
  --repository manaoscloud/mnscloud-runtime-kit \
  --minimum-version 0.1.5 \
  --validate 'bash -n scripts/*.sh lib/*.sh installers/*.sh' \
  --validate './scripts/install-tool.sh --help >/dev/null' \
  --validate './scripts/doctor.sh --help >/dev/null' \
  "$@"
