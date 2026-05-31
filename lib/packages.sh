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

mrtk_disable_default_nginx_service() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files nginx.service >/dev/null 2>&1; then
    systemctl disable --now nginx.service >/dev/null 2>&1 || true
  fi
}

mrtk_install_flutter_dependencies() {
  mrtk_detect_os
  mrtk_log "installing Flutter build dependencies"

  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    apt-get update -y
    apt-get install -y --no-install-recommends \
      ca-certificates clang cmake curl git libgtk-3-dev liblzma-dev ninja-build \
      pkg-config unzip xz-utils zip
  else
    dnf install -y \
      ca-certificates clang cmake curl git gtk3-devel libstdc++-devel ninja-build \
      pkgconf-pkg-config unzip xz zip
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

  "${flutter_dir}/bin/flutter" config --no-analytics
  if [[ "$precache_web" == "true" ]]; then
    "${flutter_dir}/bin/flutter" precache --web
  fi
  "${flutter_dir}/bin/flutter" --version
}

mrtk_ensure_flutter() {
  if command -v flutter >/dev/null 2>&1; then
    mrtk_log "flutter already installed: $(command -v flutter)"
    return 0
  fi

  mrtk_install_or_update_flutter
  command -v flutter >/dev/null 2>&1 || mrtk_die "Flutter installation failed"
}

