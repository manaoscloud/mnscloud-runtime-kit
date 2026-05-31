#!/usr/bin/env bash

mrtk_log_prefix="${MNSCLOUD_RUNTIME_KIT_LOG_PREFIX:-mnscloud-runtime-kit}"

mrtk_log() {
  printf '[%s] %s\n' "$mrtk_log_prefix" "$*"
}

mrtk_warn() {
  printf '[%s] WARNING: %s\n' "$mrtk_log_prefix" "$*" >&2
}

mrtk_die() {
  printf '[%s] ERROR: %s\n' "$mrtk_log_prefix" "$*" >&2
  exit 1
}

mrtk_require_root() {
  [[ "${EUID}" -eq 0 ]] || mrtk_die "this command must run as root"
}

