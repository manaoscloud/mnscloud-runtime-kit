#!/usr/bin/env bash

MRTK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=os.sh
source "${MRTK_LIB_DIR}/os.sh"

mrtk_install_packages() {
  mrtk_detect_os
  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    apt-get update -y
    apt-get install -y "$@"
  else
    dnf install -y "$@"
  fi
}

mrtk_install_nginx_org_repository() {
  mrtk_detect_os

  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    apt-get update -y
    apt-get install -y curl gnupg2 ca-certificates lsb-release debian-archive-keyring

    curl -fsSL https://nginx.org/keys/nginx_signing.key \
      | gpg --dearmor \
      | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

    local codename="${MRTK_OS_VERSION_CODENAME:-}"
    if [[ -z "$codename" ]]; then
      codename="$(lsb_release -cs)"
    fi

    cat > /etc/apt/sources.list.d/nginx.list <<EOF
deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/debian ${codename} nginx
EOF

    cat > /etc/apt/preferences.d/99nginx <<'EOF'
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
EOF
  else
    dnf install -y yum-utils ca-certificates curl
    cat > /etc/yum.repos.d/nginx.repo <<'EOF'
[nginx-stable]
name=nginx stable repo
baseurl=https://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true

[nginx-mainline]
name=nginx mainline repo
baseurl=https://nginx.org/packages/mainline/centos/$releasever/$basearch/
gpgcheck=1
enabled=0
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
  fi
}

mrtk_install_nginx_package() {
  if command -v nginx >/dev/null 2>&1; then
    mrtk_log "nginx already installed: $(command -v nginx)"
    return 0
  fi

  mrtk_log "nginx not found; configuring official nginx.org repository"
  mrtk_install_nginx_org_repository
  mrtk_log "installing nginx from official nginx.org repository"

  mrtk_detect_os
  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    apt-get update -y
    apt-get install -y nginx
  else
    dnf install -y nginx
  fi

  command -v nginx >/dev/null 2>&1 || mrtk_die "nginx installation failed"
}

mrtk_version_series() {
  local value="$1"
  if [[ "$value" =~ (^|[^0-9])([0-9]+)\.([0-9]+)([^0-9]|$) ]]; then
    printf '%s.%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

mrtk_apt_options() {
  local options=(-o Acquire::Retries=3)
  if [[ "${MNSCLOUD_APT_FORCE_IPV4:-true}" == "true" ]]; then
    options+=(-o Acquire::ForceIPv4=true)
  fi
  printf '%s\n' "${options[@]}"
}

mrtk_install_mariadb_org_repository() {
  mrtk_detect_os
  local version="${MNSCLOUD_MARIADB_VERSION:-12.3}"
  local repo_version="mariadb-${version}"

  mrtk_log "configuring official MariaDB repository for ${repo_version} on ${MRTK_OS_FAMILY} ${MRTK_OS_VERSION_ID}"

  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    local apt_options=()
    mapfile -t apt_options < <(mrtk_apt_options)
    apt-get "${apt_options[@]}" update
    apt-get "${apt_options[@]}" install -y curl ca-certificates gnupg apt-transport-https dirmngr
  else
    dnf install -y curl ca-certificates
  fi

  if [[ "$version" == "12.3" ]]; then
    mrtk_warn "MariaDB 12.3 is an RC repository. Do not use RC releases in production."
    if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
      local codename="${MRTK_OS_VERSION_CODENAME:-}"
      if [[ -z "$codename" ]]; then
        codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
      fi
      [[ -n "$codename" ]] || mrtk_die "cannot determine Debian codename for MariaDB repository"

      install -d -m 0755 /etc/apt/keyrings
      curl -fsSL https://mariadb.org/mariadb_release_signing_key.pgp \
        -o /etc/apt/keyrings/mariadb-keyring.asc
      cat > /etc/apt/sources.list.d/mariadb.sources <<EOF
# MariaDB 12.3 repository list
# https://mariadb.org/download/
X-Repolib-Name: MariaDB
Types: deb
URIs: https://mirror.mariadb.org/repo/12.3/debian
Suites: ${codename}
Components: main
Signed-By: /etc/apt/keyrings/mariadb-keyring.asc
EOF
    else
      cat > /etc/yum.repos.d/MariaDB.repo <<EOF
# MariaDB 12.3 repository list
# https://mariadb.org/download/
[mariadb]
name=MariaDB
baseurl=https://mirror.mariadb.org/yum/12.3/rhel/${MRTK_OS_VERSION_ID}/\$basearch
gpgkey=https://mariadb.org/mariadb_release_signing_key.pgp
gpgcheck=1
module_hotfixes=1
EOF
    fi
    return 0
  fi

  local repo_setup
  repo_setup="$(mktemp)"
  trap 'rm -f "$repo_setup"' RETURN
  curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup -o "$repo_setup"

  local os_type="$MRTK_OS_FAMILY"
  local os_version="$MRTK_OS_VERSION_ID"
  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    os_type="debian"
    os_version="${MRTK_OS_VERSION_CODENAME:-$MRTK_OS_VERSION_ID}"
  elif [[ "$MRTK_OS_FAMILY" == "rhel" ]]; then
    os_type="rhel"
  fi

  bash "$repo_setup" \
    --mariadb-server-version="${repo_version}" \
    --os-type="${os_type}" \
    --os-version="${os_version}" ||
    mrtk_die "MariaDB repository setup failed for ${repo_version} on ${os_type} ${os_version}"
}

mrtk_require_mariadb_candidate_version() {
  mrtk_detect_os
  local version="${MNSCLOUD_MARIADB_VERSION:-12.3}"
  local candidate candidate_series

  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    candidate="$(apt-cache policy mariadb-server | awk '/Candidate:/ {print $2; exit}')"
  else
    candidate="$(dnf repoquery --qf '%{version}' MariaDB-server 2>/dev/null | sort -V | tail -n 1 || true)"
  fi

  [[ -n "$candidate" && "$candidate" != "(none)" ]] ||
    mrtk_die "no MariaDB server candidate available after repository refresh"
  candidate_series="$(mrtk_version_series "$candidate" || true)"
  [[ "$candidate_series" == "$version" ]] ||
    mrtk_die "expected MariaDB candidate ${version}.x from the MariaDB repository, got ${candidate}"
}

mrtk_require_installed_mariadb_version() {
  local version="${MNSCLOUD_MARIADB_VERSION:-12.3}"
  local installed installed_series
  installed="$(mariadbd --version 2>/dev/null || mariadb --version 2>/dev/null || true)"
  installed_series="$(mrtk_version_series "$installed" || true)"
  [[ "$installed_series" == "$version" ]] ||
    mrtk_die "expected installed MariaDB ${version}.x after package installation, got: ${installed:-not installed}"
}

mrtk_install_mariadb_package() {
  local version="${MNSCLOUD_MARIADB_VERSION:-12.3}"
  if command -v mariadbd >/dev/null 2>&1 || command -v mariadb >/dev/null 2>&1; then
    mrtk_require_installed_mariadb_version
    mrtk_log "MariaDB ${version}.x already installed"
    return 0
  fi

  mrtk_install_mariadb_org_repository
  mrtk_detect_os
  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    local apt_options=()
    mapfile -t apt_options < <(mrtk_apt_options)
    apt-get "${apt_options[@]}" -o APT::Update::Error-Mode=any update
    mrtk_require_mariadb_candidate_version
    DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" install -y \
      mariadb-server mariadb-client mariadb-backup galera-4
  else
    dnf makecache
    mrtk_require_mariadb_candidate_version
    dnf install -y MariaDB-server MariaDB-client MariaDB-backup
  fi

  mrtk_require_installed_mariadb_version
  systemctl enable mariadb
  mrtk_log "MariaDB packages installed"
}

mrtk_disable_default_nginx_service() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files nginx.service >/dev/null 2>&1; then
    systemctl disable --now nginx.service >/dev/null 2>&1 || true
  fi
}

mrtk_install_flutter_dependencies() {
  mrtk_detect_os
  local build_profile="${MNSCLOUD_FLUTTER_BUILD_PROFILE:-web}"
  mrtk_log "installing Flutter ${build_profile} build dependencies"

  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    apt-get update -y
    if [[ "$build_profile" == "web" ]]; then
      apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils zip
    else
      apt-get install -y --no-install-recommends \
        ca-certificates clang cmake curl git libgtk-3-dev liblzma-dev ninja-build \
        pkg-config unzip xz-utils zip
    fi
  else
    if [[ "$build_profile" == "web" ]]; then
      dnf install -y ca-certificates curl git unzip xz zip
    else
      dnf install -y \
        ca-certificates clang cmake curl git gtk3-devel libstdc++-devel ninja-build \
        pkgconf-pkg-config unzip xz zip
    fi
  fi
}

mrtk_prepare_flutter_runner() {
  local flutter_dir="$1"
  local run_user="${MNSCLOUD_FLUTTER_RUN_USER:-}"
  local flutter_home="${MNSCLOUD_FLUTTER_HOME:-/var/lib/mnscloud-runtime-kit/flutter}"

  [[ -n "$run_user" ]] || return 0
  id -u "$run_user" >/dev/null 2>&1 || mrtk_die "Flutter run user does not exist: $run_user"

  local run_group
  run_group="$(id -gn "$run_user")"
  install -d -m 0750 -o "$run_user" -g "$run_group" "$flutter_home"
  chown -R "$run_user:$run_group" "$flutter_dir" "$flutter_home"
}

mrtk_flutter_cmd() {
  local run_user="${MNSCLOUD_FLUTTER_RUN_USER:-}"
  local flutter_home="${MNSCLOUD_FLUTTER_HOME:-/var/lib/mnscloud-runtime-kit/flutter}"
  local flutter_dir="${MNSCLOUD_FLUTTER_DIR:-/opt/flutter}"

  if [[ -n "$run_user" ]]; then
    runuser -u "$run_user" -- env \
      HOME="$flutter_home" \
      PUB_CACHE="${flutter_home}/.pub-cache" \
      PATH="${flutter_dir}/bin:${PATH}" \
      "$@"
  else
    "$@"
  fi
}

mrtk_install_or_update_flutter() {
  local flutter_dir="${MNSCLOUD_FLUTTER_DIR:-/opt/flutter}"
  local flutter_channel="${MNSCLOUD_FLUTTER_CHANNEL:-stable}"
  local flutter_repo_url="${MNSCLOUD_FLUTTER_REPO_URL:-https://github.com/flutter/flutter.git}"
  local precache_web="${MNSCLOUD_FLUTTER_PRECACHE_WEB:-true}"

  mrtk_install_flutter_dependencies

  if [[ -d "${flutter_dir}/.git" ]]; then
    mrtk_log "updating Flutter SDK in ${flutter_dir}"
    git -C "$flutter_dir" fetch origin "$flutter_channel"
    git -C "$flutter_dir" checkout "$flutter_channel"
    git -C "$flutter_dir" pull --ff-only origin "$flutter_channel"
  else
    mrtk_log "installing Flutter SDK in ${flutter_dir}"
    install -d -m 0755 "$(dirname "$flutter_dir")"
    git clone --depth 1 --branch "$flutter_channel" "$flutter_repo_url" "$flutter_dir"
  fi

  ln -sfn "${flutter_dir}/bin/flutter" /usr/local/bin/flutter
  ln -sfn "${flutter_dir}/bin/dart" /usr/local/bin/dart
  mrtk_prepare_flutter_runner "$flutter_dir"

  mrtk_flutter_cmd "${flutter_dir}/bin/flutter" config --no-analytics
  if [[ "$precache_web" == "true" ]]; then
    mrtk_flutter_cmd "${flutter_dir}/bin/flutter" precache --web
  fi
  mrtk_flutter_cmd "${flutter_dir}/bin/flutter" --version
}

mrtk_ensure_flutter() {
  if command -v flutter >/dev/null 2>&1; then
    mrtk_log "flutter already installed: $(command -v flutter)"
    return 0
  fi

  mrtk_install_or_update_flutter
  command -v flutter >/dev/null 2>&1 || mrtk_die "Flutter installation failed"
}
