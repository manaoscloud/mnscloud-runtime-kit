#!/usr/bin/env bash
set -Eeuo pipefail

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/packages.sh
source "${INSTALLER_DIR}/../lib/packages.sh"

mrtk_require_root
mrtk_ensure_dnsdist
