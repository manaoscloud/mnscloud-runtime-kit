#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/packages.sh
source "${ROOT_DIR}/lib/packages.sh"

usage() {
  cat <<EOF
Usage: scripts/doctor.sh [--tool <nginx|flutter|mariadb|deno|nodejs|docker|certbot|rabbitmq|asterisk|freeswitch|opensips|kamailio|basic-auth-utils>]
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

check_nodejs() {
  if command -v node >/dev/null 2>&1; then
    mrtk_log "node=$(command -v node)"
    node --version
  else
    mrtk_warn "node not installed"
  fi

  if command -v npm >/dev/null 2>&1; then
    mrtk_log "npm=$(command -v npm)"
    npm --version
  else
    mrtk_warn "npm not installed"
  fi
}

check_docker() {
  if command -v docker >/dev/null 2>&1; then
    mrtk_log "docker=$(command -v docker)"
    docker --version
    docker compose version || mrtk_warn "docker compose plugin not available"
  else
    mrtk_warn "docker not installed"
  fi
}

check_certbot() {
  if command -v certbot >/dev/null 2>&1; then
    mrtk_log "certbot=$(command -v certbot)"
    certbot --version
  else
    mrtk_warn "certbot not installed"
  fi
}

check_rabbitmq() {
  if command -v erl >/dev/null 2>&1; then
    mrtk_log "erl=$(command -v erl)"
    erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell
  else
    mrtk_warn "Erlang not installed"
  fi

  if command -v rabbitmq-server >/dev/null 2>&1; then
    mrtk_log "rabbitmq-server=$(command -v rabbitmq-server)"
    rabbitmq-diagnostics --version 2>/dev/null || rabbitmqctl version 2>/dev/null || true
  else
    mrtk_warn "RabbitMQ server not installed"
  fi
}

check_asterisk() {
  if command -v asterisk >/dev/null 2>&1; then
    mrtk_log "asterisk=$(command -v asterisk)"
    asterisk -V || true
  else
    mrtk_warn "Asterisk not installed"
  fi
}

check_freeswitch() {
  if command -v freeswitch >/dev/null 2>&1; then
    mrtk_log "freeswitch=$(command -v freeswitch)"
    freeswitch -version 2>/dev/null | head -n 1 || true
  else
    mrtk_warn "FreeSWITCH not installed"
  fi
}

check_opensips() {
  if command -v opensips >/dev/null 2>&1; then
    mrtk_log "opensips=$(command -v opensips)"
    opensips -V | head -n 1 || true
  else
    mrtk_warn "OpenSIPS not installed"
  fi
}

check_kamailio() {
  if command -v kamailio >/dev/null 2>&1; then
    mrtk_log "kamailio=$(command -v kamailio)"
    kamailio -v | head -n 1 || true
  else
    mrtk_warn "Kamailio not installed"
  fi
}

check_basic_auth_utils() {
  if command -v htpasswd >/dev/null 2>&1; then
    mrtk_log "htpasswd=$(command -v htpasswd)"
    htpasswd -v 2>&1 | head -n 1 || true
  else
    mrtk_warn "htpasswd not installed"
  fi
}

check_os
case "$TOOL" in
  all)
    check_nginx
    check_flutter
    check_mariadb
    check_deno
    check_nodejs
    check_docker
    check_certbot
    check_rabbitmq
    check_asterisk
    check_freeswitch
    check_opensips
    check_kamailio
    check_basic_auth_utils
    ;;
  nginx) check_nginx ;;
  flutter) check_flutter ;;
  mariadb) check_mariadb ;;
  deno) check_deno ;;
  nodejs) check_nodejs ;;
  docker) check_docker ;;
  certbot) check_certbot ;;
  rabbitmq) check_rabbitmq ;;
  asterisk) check_asterisk ;;
  freeswitch) check_freeswitch ;;
  opensips) check_opensips ;;
  kamailio) check_kamailio ;;
  basic-auth-utils) check_basic_auth_utils ;;
  *) mrtk_die "unsupported tool: $TOOL" ;;
esac
