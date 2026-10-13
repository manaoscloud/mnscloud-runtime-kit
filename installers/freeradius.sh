#!/usr/bin/env bash
set -Eeuo pipefail

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/packages.sh
source "${INSTALLER_DIR}/../lib/packages.sh"

mrtk_require_root
mrtk_detect_os
if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
  mrtk_install_packages freeradius freeradius-mysql mariadb-client python3 ca-certificates curl
else
  mrtk_install_packages freeradius freeradius-mysql mariadb python3 ca-certificates curl
fi

minimum="${MNSCLOUD_FREERADIUS_MIN_VERSION:-3.2.5}"
[[ "$minimum" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || mrtk_die 'Invalid authentication minimum version'
[[ "$(printf '%s\n' 3.2.5 "$minimum" | sort -V | head -n1)" == 3.2.5 ]] || mrtk_die 'The authentication security floor cannot be lowered'
# Never silently deploy an engine predating the upstream security baseline.
binary="$(command -v freeradius || command -v radiusd)"
version="$("$binary" -v 2>/dev/null | sed -nE 's/.*Version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n1)"
[[ -n "$version" ]] || mrtk_die 'Unable to verify the network authentication engine version'
[[ "$(printf '%s\n' "$minimum" "$version" | sort -V | head -n1)" == "$minimum" ]] ||
  mrtk_die 'Network authentication requires an approved package version 3.2.5 or newer; configure a supported package source before installation'
