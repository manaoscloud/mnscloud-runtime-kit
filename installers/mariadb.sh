#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/packages.sh
source "${SCRIPT_DIR}/../lib/packages.sh"

mrtk_require_root
mrtk_install_mariadb_package
