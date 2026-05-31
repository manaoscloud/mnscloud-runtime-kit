#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/packages.sh
source "${ROOT_DIR}/lib/packages.sh"

usage() {
  cat <<EOF
Usage: scripts/doctor.sh [--tool <nginx|flutter|mariadb|deno>]
EOF
}

TOOL="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool) TOOL="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) mrtk_die "unknown argument: $1" ;;
  esac
done

check_os() {
  mrtk_detect_os
  mrtk_log "os=${MRTK_OS_PRETTY_NAME} family=${MRTK_OS_FAMILY}"
}

check_nginx() {
  if command -v nginx >/dev/null 2>&1; then
    mrtk_log "nginx=$(command -v nginx)"
    nginx -v
  else
    mrtk_warn "nginx not installed"
  fi
}

check_mariadb() {
  if command -v mariadb >/dev/null 2>&1; then
    mrtk_log "mariadb=$(command -v mariadb)"
    mariadb --version
  else
    mrtk_warn "mariadb client not installed"
  fi

  if command -v mariadbd >/dev/null 2>&1; then
    mrtk_log "mariadbd=$(command -v mariadbd)"
    mariadbd --version
  else
    mrtk_warn "mariadbd server not installed"
  fi
}

check_flutter() {
  if command -v flutter >/dev/null 2>&1; then
    mrtk_log "flutter=$(command -v flutter)"
    flutter --version
  else
    mrtk_warn "flutter not installed"
  fi
  if command -v dart >/dev/null 2>&1; then
    mrtk_log "dart=$(command -v dart)"
    dart --version
  else
    mrtk_warn "dart not installed"
  fi
}

check_deno() {
  if command -v deno >/dev/null 2>&1; then
    mrtk_log "deno=$(command -v deno)"
    deno --version
  else
    mrtk_warn "deno not installed"
  fi
}

check_os
case "$TOOL" in
  all)
    check_nginx
    check_flutter
    check_mariadb
    check_deno
    ;;
  nginx) check_nginx ;;
  flutter) check_flutter ;;
  mariadb) check_mariadb ;;
  deno) check_deno ;;
  *) mrtk_die "unsupported tool: $TOOL" ;;
esac
