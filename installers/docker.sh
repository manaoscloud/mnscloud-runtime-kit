#!/usr/bin/env bash
set -Eeuo pipefail

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${INSTALLER_DIR}/.." && pwd)"
# shellcheck source=../lib/packages.sh
source "${ROOT_DIR}/lib/packages.sh"

mrtk_require_root
mrtk_install_docker_package
