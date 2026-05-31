#!/usr/bin/env bash

MRTK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=logging.sh
source "${MRTK_LIB_DIR}/logging.sh"

mrtk_detect_os() {
  [[ -r /etc/os-release ]] || mrtk_die "/etc/os-release not found"
  # shellcheck disable=SC1091
  source /etc/os-release

  MRTK_OS_ID="${ID:-}"
  MRTK_OS_VERSION_ID="${VERSION_ID:-}"
  MRTK_OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
  MRTK_OS_PRETTY_NAME="${PRETTY_NAME:-${MRTK_OS_ID} ${MRTK_OS_VERSION_ID}}"

  case "${MRTK_OS_ID}:${MRTK_OS_VERSION_ID}" in
    debian:12|debian:13)
      MRTK_OS_FAMILY="debian"
      ;;
    rhel:9*|rhel:10*|rocky:9*|rocky:10*|almalinux:9*|almalinux:10*)
      MRTK_OS_FAMILY="rhel"
      ;;
    *)
      mrtk_die "unsupported OS: ${MRTK_OS_PRETTY_NAME}. Supported: Debian 12/13 and RHEL/Rocky/AlmaLinux 9/10"
      ;;
  esac

  export MRTK_OS_ID MRTK_OS_VERSION_ID MRTK_OS_VERSION_CODENAME MRTK_OS_PRETTY_NAME MRTK_OS_FAMILY
}

