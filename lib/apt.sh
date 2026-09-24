#!/usr/bin/env bash
# apt/dpkg lock handling shared by runtime installers.
#
# unattended-upgrades and apt-daily often hold the dpkg frontend lock or the apt lists
# lock right after boot. Plain apt-get then fails immediately with exit 100. Every apt
# call made through mrtk_apt_get first waits for those locks, and installs also get
# DPkg::Lock::Timeout through a transient APT_CONFIG to cover the remaining race.

MRTK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=logging.sh
source "${MRTK_LIB_DIR}/logging.sh"

MRTK_APT_LOCK_TIMEOUT="${MNSCLOUD_APT_LOCK_TIMEOUT:-600}"
MRTK_APT_LOCK_PATTERN='^/var/lib/(dpkg/lock|dpkg/lock-frontend|apt/lists/lock|apt/archives/lock)$'

# Transient apt configuration; never changes /etc/apt on the host.
mrtk_apt_lock_config() {
  local config
  [[ -z "${APT_CONFIG:-}" ]] || return 0
  [[ "$MRTK_APT_LOCK_TIMEOUT" =~ ^[0-9]+$ ]] || MRTK_APT_LOCK_TIMEOUT=600
  config="$(mktemp "${TMPDIR:-/tmp}/mnscloud-apt-lock.XXXXXX")" || return 0
  printf 'DPkg::Lock::Timeout "%s";\n' "$MRTK_APT_LOCK_TIMEOUT" >"$config"
  chmod 0644 "$config"
  export APT_CONFIG="$config"
}

mrtk_apt_locks_held() {
  command -v lslocks >/dev/null 2>&1 || return 1
  lslocks --noheadings --output PATH 2>/dev/null | grep -qE "$MRTK_APT_LOCK_PATTERN"
}

# Waits up to MNSCLOUD_APT_LOCK_TIMEOUT seconds; on timeout apt-get still runs and reports.
mrtk_apt_wait_locks() {
  local waited=0
  while mrtk_apt_locks_held; do
    if (( waited >= MRTK_APT_LOCK_TIMEOUT )); then
      mrtk_warn "apt/dpkg lock still held after ${waited}s; continuing so apt-get reports the holder"
      return 0
    fi
    if (( waited % 30 == 0 )); then
      mrtk_log "waiting for another apt/dpkg process (for example unattended-upgrades) to release its lock (${waited}s/${MRTK_APT_LOCK_TIMEOUT}s)"
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

mrtk_apt_get() {
  mrtk_apt_lock_config
  mrtk_apt_wait_locks
  command apt-get "$@"
}
