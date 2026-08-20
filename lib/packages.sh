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

mrtk_install_deno_dependencies() {
  mrtk_detect_os
  mrtk_log "installing Deno installer dependencies"

  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates curl unzip
  else
    dnf install -y ca-certificates curl unzip
  fi
}

mrtk_deno_bin() {
  local install_dir="${MNSCLOUD_DENO_INSTALL_DIR:-/usr/local/deno}"
  printf '%s/bin/deno\n' "$install_dir"
}

mrtk_installed_deno_version() {
  local deno_bin
  deno_bin="$(mrtk_deno_bin)"

  if [[ -x "$deno_bin" ]]; then
    "$deno_bin" --version 2>/dev/null | awk '/^deno / {print $2; exit}'
    return 0
  fi

  if command -v deno >/dev/null 2>&1; then
    deno --version 2>/dev/null | awk '/^deno / {print $2; exit}'
  fi
}

mrtk_install_or_update_deno() {
  local version="${MNSCLOUD_DENO_VERSION:-2.8.1}"
  local install_dir="${MNSCLOUD_DENO_INSTALL_DIR:-/usr/local/deno}"
  local installed_version
  installed_version="$(mrtk_installed_deno_version || true)"

  if [[ "$installed_version" == "$version" ]]; then
    mrtk_log "Deno ${version} already installed"
    return 0
  fi

  mrtk_install_deno_dependencies
  install -d -m 0755 "$install_dir" /usr/local/bin

  mrtk_log "installing Deno ${version} with official deno.land installer"
  CI=1 DENO_INSTALL="$install_dir" sh -c \
    "curl -fsSL https://deno.land/install.sh | sh -s -- --no-modify-path v${version}"

  ln -sfn "${install_dir}/bin/deno" /usr/local/bin/deno
  ln -sfn "${install_dir}/bin/deno" /usr/bin/deno 2>/dev/null || true

  installed_version="$(mrtk_installed_deno_version || true)"
  [[ "$installed_version" == "$version" ]] ||
    mrtk_die "expected Deno ${version} after installation, got ${installed_version:-not installed}"
  mrtk_log "Deno ${version} installed"
}

mrtk_ensure_deno() {
  mrtk_install_or_update_deno
  command -v deno >/dev/null 2>&1 || mrtk_die "Deno installation failed"
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

mrtk_node_major_version() {
  if ! command -v node >/dev/null 2>&1; then
    printf '0\n'
    return 0
  fi

  node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || printf '0\n'
}

mrtk_nodejs_is_usable() {
  local expected_major="${MNSCLOUD_NODE_MAJOR_VERSION:-24}"
  local installed_major
  installed_major="$(mrtk_node_major_version)"
  [[ "$installed_major" -ge "$expected_major" ]] && command -v npm >/dev/null 2>&1
}

mrtk_install_nodesource_repository() {
  mrtk_detect_os
  local major="${MNSCLOUD_NODE_MAJOR_VERSION:-24}"

  mrtk_log "configuring official NodeSource repository for Node.js ${major}.x"
  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates curl gnupg
    curl -fsSL "https://deb.nodesource.com/setup_${major}.x" | bash -
  else
    dnf install -y ca-certificates curl
    curl -fsSL "https://rpm.nodesource.com/setup_${major}.x" | bash -
  fi
}

mrtk_install_nodejs_package() {
  local major="${MNSCLOUD_NODE_MAJOR_VERSION:-24}"

  if mrtk_nodejs_is_usable; then
    mrtk_log "Node.js $(node -v) and npm $(npm -v) already installed"
    return 0
  fi

  mrtk_install_nodesource_repository
  mrtk_detect_os
  mrtk_log "installing Node.js ${major}.x from official NodeSource repository"
  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    apt-get install -y --no-install-recommends nodejs
  else
    dnf install -y nodejs
  fi

  mrtk_nodejs_is_usable ||
    mrtk_die "expected Node.js ${major}.x with npm after installation"
  mrtk_log "Node.js $(node -v) and npm $(npm -v) installed"
}

mrtk_ensure_nodejs() {
  mrtk_install_nodejs_package
  command -v node >/dev/null 2>&1 || mrtk_die "Node.js installation failed"
  command -v npm >/dev/null 2>&1 || mrtk_die "npm installation failed"
}

mrtk_install_docker_repository() {
  mrtk_detect_os
  mrtk_log "configuring official Docker repository"

  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    rm -f /etc/apt/keyrings/docker.gpg
    curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    local codename="${MRTK_OS_VERSION_CODENAME:-}"
    if [[ -z "$codename" ]]; then
      codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    fi
    [[ -n "$codename" ]] || mrtk_die "cannot determine Debian codename for Docker repository"

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable
EOF
  else
    dnf install -y dnf-plugins-core ca-certificates curl

    local os_major="${MRTK_OS_VERSION_ID%%.*}"
    local repo_url="https://download.docker.com/linux/rhel/docker-ce.repo"
    if [[ "$MRTK_OS_ID" == "rocky" || "$MRTK_OS_ID" == "almalinux" ]]; then
      repo_url="https://download.docker.com/linux/centos/docker-ce.repo"
      if [[ "$os_major" == "10" ]]; then
        repo_url="https://download.docker.com/linux/rhel/docker-ce.repo"
      fi
    fi

    if dnf config-manager --help 2>&1 | grep -q -- '--add-repo'; then
      dnf config-manager --add-repo "$repo_url"
    else
      dnf config-manager addrepo --from-repofile="$repo_url"
    fi
  fi
}

mrtk_docker_is_usable() {
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

mrtk_install_docker_package() {
  if mrtk_docker_is_usable; then
    mrtk_log "Docker already installed: $(docker --version); $(docker compose version)"
    return 0
  fi

  mrtk_install_docker_repository
  mrtk_detect_os
  mrtk_log "installing Docker Engine and Compose plugin from official Docker repository"
  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable docker
    systemctl start docker
  fi

  mrtk_docker_is_usable || mrtk_die "Docker Engine with Compose plugin is required"
  mrtk_log "Docker installed: $(docker --version); $(docker compose version)"
}

mrtk_ensure_docker() {
  mrtk_install_docker_package
  mrtk_docker_is_usable || mrtk_die "Docker Engine with Compose plugin is required"
}

mrtk_install_basic_auth_utils() {
  if command -v htpasswd >/dev/null 2>&1; then
    mrtk_log "htpasswd already installed: $(command -v htpasswd)"
    return 0
  fi

  mrtk_detect_os
  mrtk_log "installing HTTP basic-auth utility package"
  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    apt-get update -y
    apt-get install -y --no-install-recommends apache2-utils
  else
    dnf install -y httpd-tools
  fi

  command -v htpasswd >/dev/null 2>&1 || mrtk_die "htpasswd installation failed"
}

mrtk_ensure_basic_auth_utils() {
  mrtk_install_basic_auth_utils
}

mrtk_certbot_is_usable() {
  command -v certbot >/dev/null 2>&1
}

mrtk_certbot_snap_is_installed() {
  command -v snap >/dev/null 2>&1 && snap list certbot >/dev/null 2>&1
}

mrtk_remove_os_certbot_packages() {
  mrtk_detect_os
  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    apt-get remove -y certbot python3-certbot python3-certbot-nginx 2>/dev/null || true
  else
    dnf remove -y certbot python3-certbot-nginx 2>/dev/null || true
  fi
}

mrtk_install_epel_for_snapd() {
  mrtk_detect_os
  [[ "$MRTK_OS_FAMILY" == "rhel" ]] || return 0

  local os_major="${MRTK_OS_VERSION_ID%%.*}"
  case "$os_major" in
    9|10)
      dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${os_major}.noarch.rpm" ||
        mrtk_die "failed to install EPEL release for snapd on RHEL-compatible ${os_major}"
      ;;
    *)
      mrtk_die "snapd is not configured for this RHEL-compatible version: ${MRTK_OS_VERSION_ID}"
      ;;
  esac
}

mrtk_install_certbot_package() {
  if mrtk_certbot_is_usable && mrtk_certbot_snap_is_installed; then
    mrtk_log "certbot already installed: $(command -v certbot)"
    return 0
  fi

  mrtk_detect_os
  mrtk_remove_os_certbot_packages
  mrtk_log "installing Certbot with the upstream-recommended snap package"
  if [[ "$MRTK_OS_FAMILY" == "debian" ]]; then
    apt-get update -y
    apt-get install -y --no-install-recommends snapd
  else
    mrtk_install_epel_for_snapd
    dnf install -y snapd
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now snapd.socket
    ln -sfn /var/lib/snapd/snap /snap 2>/dev/null || true
  fi

  snap install core >/dev/null 2>&1 || true
  snap refresh core >/dev/null 2>&1 || true
  snap install --classic certbot
  ln -sfn /snap/bin/certbot /usr/bin/certbot

  mrtk_certbot_is_usable || mrtk_die "certbot installation failed"
  mrtk_certbot_snap_is_installed || mrtk_die "expected certbot snap to be installed"
  mrtk_log "Certbot installed: $(certbot --version)"
}

mrtk_enable_certbot_timer() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  if systemctl list-unit-files certbot.timer >/dev/null 2>&1; then
    systemctl enable --now certbot.timer
  elif systemctl list-unit-files snap.certbot.renew.timer >/dev/null 2>&1; then
    systemctl enable --now snap.certbot.renew.timer
  else
    mrtk_warn "no Certbot renewal timer unit found"
  fi
}

mrtk_ensure_certbot() {
  mrtk_install_certbot_package
  mrtk_certbot_is_usable || mrtk_die "certbot installation failed"
}

mrtk_detect_rabbitmq_os() {
  [[ -r /etc/os-release ]] || mrtk_die "/etc/os-release not found"
  # shellcheck disable=SC1091
  source /etc/os-release

  MRTK_RABBITMQ_OS_ID="${ID:-}"
  MRTK_RABBITMQ_OS_VERSION_ID="${VERSION_ID:-}"
  MRTK_RABBITMQ_OS_MAJOR="${MRTK_RABBITMQ_OS_VERSION_ID%%.*}"
  MRTK_RABBITMQ_OS_CODENAME="${VERSION_CODENAME:-}"
  MRTK_RABBITMQ_OS_PRETTY_NAME="${PRETTY_NAME:-${MRTK_RABBITMQ_OS_ID} ${MRTK_RABBITMQ_OS_VERSION_ID}}"

  case "${MRTK_RABBITMQ_OS_ID}:${MRTK_RABBITMQ_OS_MAJOR}" in
    debian:12)
      MRTK_RABBITMQ_OS_FAMILY="debian"
      MRTK_RABBITMQ_DEBIAN_CODENAME="${MRTK_RABBITMQ_OS_CODENAME:-bookworm}"
      ;;
    debian:13)
      MRTK_RABBITMQ_OS_FAMILY="debian"
      MRTK_RABBITMQ_DEBIAN_CODENAME="${MRTK_RABBITMQ_OS_CODENAME:-trixie}"
      ;;
    rhel:8|rhel:9|rocky:8|rocky:9|almalinux:8|almalinux:9)
      MRTK_RABBITMQ_OS_FAMILY="rhel"
      ;;
    *)
      mrtk_die "unsupported RabbitMQ OS: ${MRTK_RABBITMQ_OS_PRETTY_NAME}. Supported: Debian 12/13 and RHEL/Rocky/AlmaLinux 8/9"
      ;;
  esac

  export MRTK_RABBITMQ_OS_ID MRTK_RABBITMQ_OS_VERSION_ID MRTK_RABBITMQ_OS_MAJOR
  export MRTK_RABBITMQ_OS_CODENAME MRTK_RABBITMQ_OS_PRETTY_NAME MRTK_RABBITMQ_OS_FAMILY
  export MRTK_RABBITMQ_DEBIAN_CODENAME
}

mrtk_rabbitmq_debian_erlang_packages() {
  cat <<'EOF'
erlang-base
erlang-asn1
erlang-crypto
erlang-eldap
erlang-ftp
erlang-inets
erlang-mnesia
erlang-os-mon
erlang-parsetools
erlang-public-key
erlang-runtime-tools
erlang-snmp
erlang-ssl
erlang-syntax-tools
erlang-tftp
erlang-tools
erlang-xmerl
EOF
}

mrtk_configure_rabbitmq_debian_repository() {
  mrtk_detect_rabbitmq_os
  [[ "$MRTK_RABBITMQ_OS_FAMILY" == "debian" ]] ||
    mrtk_die "RabbitMQ Debian repository requested on non-Debian host"

  local apt_options=()
  mapfile -t apt_options < <(mrtk_apt_options)

  mrtk_log "configuring official Team RabbitMQ apt repositories for ${MRTK_RABBITMQ_DEBIAN_CODENAME}"
  apt-get "${apt_options[@]}" update
  apt-get "${apt_options[@]}" install -y --no-install-recommends \
    curl ca-certificates gnupg apt-transport-https

  install -d -m 0755 /etc/apt/keyrings
  rm -f /etc/apt/keyrings/com.rabbitmq.team.gpg /etc/apt/keyrings/rabbitmq-release-signing-key.gpg
  curl -1sLf 'https://keys.openpgp.org/vks/v1/by-fingerprint/0A9AF2115F4687BD29803A206B73A36E6026DFCA' \
    | gpg --dearmor > /etc/apt/keyrings/com.rabbitmq.team.gpg
  curl -1sLf 'https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc' \
    | gpg --dearmor > /etc/apt/keyrings/rabbitmq-release-signing-key.gpg

  cat > /etc/apt/sources.list.d/rabbitmq.list <<EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/com.rabbitmq.team.gpg] https://deb1.rabbitmq.com/rabbitmq-erlang/debian/${MRTK_RABBITMQ_DEBIAN_CODENAME} ${MRTK_RABBITMQ_DEBIAN_CODENAME} main
deb [arch=amd64 signed-by=/etc/apt/keyrings/com.rabbitmq.team.gpg] https://deb2.rabbitmq.com/rabbitmq-erlang/debian/${MRTK_RABBITMQ_DEBIAN_CODENAME} ${MRTK_RABBITMQ_DEBIAN_CODENAME} main
deb [arch=amd64 signed-by=/etc/apt/keyrings/rabbitmq-release-signing-key.gpg] https://deb1.rabbitmq.com/rabbitmq-server/debian/${MRTK_RABBITMQ_DEBIAN_CODENAME} ${MRTK_RABBITMQ_DEBIAN_CODENAME} main
deb [arch=amd64 signed-by=/etc/apt/keyrings/rabbitmq-release-signing-key.gpg] https://deb2.rabbitmq.com/rabbitmq-server/debian/${MRTK_RABBITMQ_DEBIAN_CODENAME} ${MRTK_RABBITMQ_DEBIAN_CODENAME} main
EOF

  apt-get "${apt_options[@]}" update
}

mrtk_configure_rabbitmq_rhel_repository() {
  mrtk_detect_rabbitmq_os
  [[ "$MRTK_RABBITMQ_OS_FAMILY" == "rhel" ]] ||
    mrtk_die "RabbitMQ RPM repository requested on non-RHEL-compatible host"

  mrtk_log "configuring official RabbitMQ yum repositories"
  dnf install -y curl ca-certificates yum-utils
  cat > /etc/yum.repos.d/rabbitmq.repo <<'EOF'
[modern-erlang]
name=modern-erlang-el
baseurl=https://yum1.rabbitmq.com/erlang/el/$releasever/$basearch
        https://yum2.rabbitmq.com/erlang/el/$releasever/$basearch
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc
       https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-erlang-release-signing-key.asc
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
pkg_gpgcheck=1
autorefresh=1
type=rpm-md

[rabbitmq-server]
name=rabbitmq-server-el
baseurl=https://yum1.rabbitmq.com/rabbitmq/el/$releasever/$basearch
        https://yum2.rabbitmq.com/rabbitmq/el/$releasever/$basearch
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
pkg_gpgcheck=1
autorefresh=1
type=rpm-md
EOF
}

mrtk_configure_rabbitmq_repository() {
  mrtk_detect_rabbitmq_os
  if [[ "$MRTK_RABBITMQ_OS_FAMILY" == "debian" ]]; then
    mrtk_configure_rabbitmq_debian_repository
  else
    mrtk_configure_rabbitmq_rhel_repository
  fi
}

mrtk_install_rabbitmq_package() {
  mrtk_configure_rabbitmq_repository
  mrtk_detect_rabbitmq_os

  mrtk_log "installing RabbitMQ and Erlang from official RabbitMQ repositories"
  if [[ "$MRTK_RABBITMQ_OS_FAMILY" == "debian" ]]; then
    local apt_options=()
    local erlang_packages=()
    mapfile -t apt_options < <(mrtk_apt_options)
    mapfile -t erlang_packages < <(mrtk_rabbitmq_debian_erlang_packages)
    DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" install -y \
      "${erlang_packages[@]}" rabbitmq-server
  else
    dnf install -y erlang rabbitmq-server
  fi

  command -v erl >/dev/null 2>&1 || mrtk_die "Erlang installation failed"
  command -v rabbitmq-server >/dev/null 2>&1 || mrtk_die "RabbitMQ server installation failed"
  command -v rabbitmq-diagnostics >/dev/null 2>&1 || mrtk_die "RabbitMQ diagnostics CLI installation failed"
}

mrtk_update_rabbitmq_package() {
  mrtk_configure_rabbitmq_repository
  mrtk_detect_rabbitmq_os

  mrtk_log "updating RabbitMQ and Erlang packages"
  if [[ "$MRTK_RABBITMQ_OS_FAMILY" == "debian" ]]; then
    local apt_options=()
    local erlang_packages=()
    mapfile -t apt_options < <(mrtk_apt_options)
    mapfile -t erlang_packages < <(mrtk_rabbitmq_debian_erlang_packages)
    DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" install -y \
      "${erlang_packages[@]}" rabbitmq-server
  else
    dnf update -y erlang rabbitmq-server
  fi

  command -v erl >/dev/null 2>&1 || mrtk_die "Erlang installation failed"
  command -v rabbitmq-server >/dev/null 2>&1 || mrtk_die "RabbitMQ server installation failed"
}

mrtk_ensure_rabbitmq() {
  mrtk_install_rabbitmq_package
}

mrtk_detect_telephony_os() {
  [[ -r /etc/os-release ]] || mrtk_die "/etc/os-release not found"
  # shellcheck disable=SC1091
  source /etc/os-release

  MRTK_TELEPHONY_OS_ID="${ID:-}"
  MRTK_TELEPHONY_OS_VERSION_ID="${VERSION_ID:-}"
  MRTK_TELEPHONY_OS_MAJOR="${MRTK_TELEPHONY_OS_VERSION_ID%%.*}"
  MRTK_TELEPHONY_OS_CODENAME="${VERSION_CODENAME:-}"
  MRTK_TELEPHONY_OS_PRETTY_NAME="${PRETTY_NAME:-${MRTK_TELEPHONY_OS_ID} ${MRTK_TELEPHONY_OS_VERSION_ID}}"

  case "${MRTK_TELEPHONY_OS_ID}:${MRTK_TELEPHONY_OS_MAJOR}" in
    debian:12|debian:13)
      MRTK_TELEPHONY_OS_FAMILY="debian"
      ;;
    rocky:8|rocky:9)
      MRTK_TELEPHONY_OS_FAMILY="rocky"
      ;;
    *)
      mrtk_die "unsupported telephony OS: ${MRTK_TELEPHONY_OS_PRETTY_NAME}. Supported: Debian 12/13 and Rocky Linux 8/9"
      ;;
  esac

  export MRTK_TELEPHONY_OS_ID MRTK_TELEPHONY_OS_VERSION_ID MRTK_TELEPHONY_OS_MAJOR
  export MRTK_TELEPHONY_OS_CODENAME MRTK_TELEPHONY_OS_PRETTY_NAME MRTK_TELEPHONY_OS_FAMILY
}

mrtk_ensure_asterisk_build_deps() {
  mrtk_detect_telephony_os
  [[ "$MRTK_TELEPHONY_OS_FAMILY" == "debian" ]] ||
    mrtk_die "Asterisk build dependencies are currently supported on Debian 12/13"

  mrtk_log "installing Asterisk build and runtime dependencies from Debian repositories"
  apt-get update -y
  apt-get install -y --no-install-recommends \
    build-essential git curl wget ca-certificates gnupg pkg-config autoconf automake \
    libtool bison flex make patch libedit-dev libjansson-dev libxml2-dev libsqlite3-dev \
    uuid-dev libssl-dev libcurl4-openssl-dev libnewt-dev libncurses5-dev libncurses-dev \
    unixodbc unixodbc-dev odbc-mariadb default-mysql-client libbcg729-0 libbcg729-dev \
    sngrep tcpdump wireshark-common ngrep dnsutils iputils-ping traceroute mtr-tiny netcat-openbsd jq

  if apt-cache show asterisk-codec-bcg729 >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends asterisk-codec-bcg729 ||
      mrtk_warn "optional package asterisk-codec-bcg729 could not be installed"
  else
    mrtk_warn "optional package asterisk-codec-bcg729 was not found"
  fi
}

mrtk_configure_freeswitch_repository() {
  mrtk_detect_telephony_os
  [[ "$MRTK_TELEPHONY_OS_ID:$MRTK_TELEPHONY_OS_VERSION_ID" == "debian:12" ]] ||
    mrtk_die "FreeSWITCH packages are currently supported on Debian 12"

  local token="${MNSCLOUD_FREESWITCH_SIGNALWIRE_TOKEN:-${SIGNALWIRE_REPO_TOKEN:-}}"
  [[ -n "$token" ]] || mrtk_die "SignalWire repository token is required for FreeSWITCH"

  mrtk_log "configuring official FreeSWITCH SignalWire repository"
  apt-get update -y
  apt-get install -y --no-install-recommends ca-certificates curl gnupg
  curl -fsSL https://freeswitch.org/fsget | bash -s "$token" release

  if [[ -n "${MNSCLOUD_FREESWITCH_REPO_SUITE:-${FREESWITCH_REPO_SUITE:-}}" ]]; then
    local suite="${MNSCLOUD_FREESWITCH_REPO_SUITE:-${FREESWITCH_REPO_SUITE:-}}"
    mrtk_log "forcing FreeSWITCH repository suite to ${suite}"
    sed -i "s/^Suites: .*/Suites: ${suite}/" /etc/apt/sources.list.d/freeswitch.sources
  fi

  apt-get update -y
}

mrtk_cleanup_freeswitch_packages() {
  local status
  status="$(dpkg-query -W -f='${db:Status-Abbrev}\n' ssmtp freeswitch-mod-voicemail freeswitch-meta-all 2>/dev/null || true)"
  if printf '%s\n' "$status" | grep -Eq '^[ih]?[UF]'; then
    mrtk_warn "cleaning broken optional FreeSWITCH meta packages"
    DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge \
      freeswitch-meta-all freeswitch-mod-voicemail ssmtp || true
  fi
  if dpkg-query -W -f='${db:Status-Abbrev}' freeswitch-mod-g729 >/dev/null 2>&1; then
    mrtk_warn "removing freeswitch-mod-g729 to keep only free G.729 through bcg729"
    DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge freeswitch-mod-g729 || true
  fi
}

mrtk_apt_install_optional() {
  local package="$1" description="${2:-$1}"
  if ! apt-cache show "$package" >/dev/null 2>&1; then
    mrtk_warn "optional package ${package} not found. Skipping ${description}."
    return 1
  fi
  apt-get install -y --no-install-recommends "$package" && return 0
  mrtk_warn "optional package ${package} could not be installed. Skipping ${description}."
  return 1
}

mrtk_dnf_install_optional() {
  local package="$1" description="${2:-$1}"
  if ! dnf repoquery --quiet --available "$package" >/dev/null 2>&1; then
    mrtk_warn "optional package ${package} not found. Skipping ${description}."
    return 1
  fi
  dnf install -y "$package" && return 0
  mrtk_warn "optional package ${package} could not be installed. Skipping ${description}."
  return 1
}

mrtk_install_freeswitch_package() {
  mrtk_configure_freeswitch_repository
  mrtk_cleanup_freeswitch_packages

  if ! apt-cache show freeswitch freeswitch-systemd freeswitch-conf-vanilla >/dev/null 2>&1; then
    mrtk_die "FreeSWITCH packages were not found for the current suite. Use Debian 12 or set FREESWITCH_REPO_SUITE=bookworm."
  fi

  mrtk_log "installing FreeSWITCH packages"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    freeswitch freeswitch-systemd freeswitch-conf-vanilla \
    freeswitch-mod-sofia freeswitch-mod-dptools freeswitch-mod-dialplan-xml freeswitch-mod-xml-curl \
    freeswitch-mod-curl freeswitch-mod-commands freeswitch-mod-event-socket \
    freeswitch-mod-console freeswitch-mod-logfile freeswitch-mod-db \
    freeswitch-mod-hash freeswitch-mod-lua freeswitch-mod-conference \
    freeswitch-mod-callcenter \
    freeswitch-mod-opus freeswitch-mod-av freeswitch-mod-sndfile freeswitch-mod-native-file \
    freeswitch-mod-local-stream freeswitch-mod-tone-stream freeswitch-mod-say-en \
    freeswitch-mod-json-cdr freeswitch-mod-mariadb freeswitch-mod-http-cache \
    build-essential git cmake pkg-config \
    unixodbc odbc-mariadb libbcg729-0 libbcg729-dev \
    sngrep tcpdump wireshark-common ngrep dnsutils iputils-ping traceroute mtr-tiny netcat-openbsd jq

  mrtk_apt_install_optional "libfreeswitch-dev" "FreeSWITCH headers for optional mod_bcg729 build" ||
    mrtk_apt_install_optional "freeswitch-dev" "FreeSWITCH headers for optional mod_bcg729 build" ||
    mrtk_warn "FreeSWITCH headers package not found"
  mrtk_apt_install_optional "freeswitch-mod-bcg729" "prebuilt FreeSWITCH bcg729 module" || true

  command -v freeswitch >/dev/null 2>&1 || mrtk_die "FreeSWITCH installation failed"
}

mrtk_ensure_freeswitch() {
  mrtk_install_freeswitch_package
}

mrtk_configure_opensips_repository() {
  mrtk_detect_telephony_os
  local version="${MNSCLOUD_OPENSIPS_VERSION:-3.6}"

  if [[ "$MRTK_TELEPHONY_OS_FAMILY" == "debian" ]]; then
    local codename="${MRTK_TELEPHONY_OS_CODENAME:-}"
    case "$codename" in
      bookworm) ;;
      *) mrtk_die "OpenSIPS ${version}.x repository is supported only on Debian bookworm" ;;
    esac
    mrtk_log "configuring official OpenSIPS ${version}.x apt repository"
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates curl gnupg
    install -m 0755 -d /usr/share/keyrings
    rm -f /usr/share/keyrings/opensips.gpg.tmp
    curl -fsSL https://apt.opensips.org/opensips-org.gpg \
      | gpg --dearmor -o /usr/share/keyrings/opensips.gpg.tmp
    mv /usr/share/keyrings/opensips.gpg.tmp /usr/share/keyrings/opensips.gpg
    chmod 0644 /usr/share/keyrings/opensips.gpg
    cat > /etc/apt/sources.list.d/opensips.list <<EOF
deb [signed-by=/usr/share/keyrings/opensips.gpg] https://apt.opensips.org ${codename} ${version}-releases
EOF
    apt-get update -y
  else
    local major="$MRTK_TELEPHONY_OS_MAJOR"
    mrtk_log "configuring official OpenSIPS ${version}.x yum repository"
    dnf install -y epel-release dnf-plugins-core ca-certificates curl
    rpm --import https://yum.opensips.org/opensips-org.gpg
    cat > /etc/yum.repos.d/opensips.repo <<EOF
[opensips-${version}]
name=OpenSIPS ${version}.x official repository
baseurl=https://yum.opensips.org/${version}/releases/st/${major}/\$basearch/
enabled=1
gpgcheck=1
gpgkey=https://yum.opensips.org/opensips-org.gpg
EOF
    dnf clean all
    dnf makecache --repo "opensips-${version}"
  fi
}

mrtk_install_opensips_package() {
  mrtk_configure_opensips_repository
  mrtk_detect_telephony_os

  mrtk_log "installing OpenSIPS packages"
  if [[ "$MRTK_TELEPHONY_OS_FAMILY" == "debian" ]]; then
    apt-get install -y --no-install-recommends \
      opensips opensips-auth-modules opensips-http-modules opensips-json-module opensips-restclient-module \
      opensips-tls-module sngrep tcpdump wireshark-common ngrep dnsutils iputils-ping traceroute \
      mtr-tiny netcat-openbsd jq ca-certificates curl
    mrtk_apt_install_optional "opensips-rtpengine-module" "OpenSIPS rtpengine module package" ||
      mrtk_warn "OpenSIPS rtpengine module package is not separate in this repository"
  else
    dnf install -y \
      opensips opensips-auth-modules opensips-http-modules opensips-json-module opensips-restclient-module \
      sngrep tcpdump wireshark-cli ngrep bind-utils iputils traceroute mtr nc jq curl ca-certificates
    mrtk_dnf_install_optional "opensips-rtpengine-module" "OpenSIPS rtpengine module package" ||
      mrtk_warn "OpenSIPS rtpengine module package is not separate in this repository"
  fi

  command -v opensips >/dev/null 2>&1 || mrtk_die "OpenSIPS installation failed"
}

mrtk_ensure_opensips() {
  mrtk_install_opensips_package
}

mrtk_configure_kamailio_repository() {
  mrtk_detect_telephony_os
  local version="${MNSCLOUD_KAMAILIO_VERSION:-6.1}"

  if [[ "$MRTK_TELEPHONY_OS_FAMILY" == "debian" ]]; then
    local codename="${MRTK_TELEPHONY_OS_CODENAME:-}"
    case "$codename" in
      bookworm|trixie) ;;
      *) mrtk_die "Kamailio ${version}.x repository is supported only on Debian bookworm/trixie" ;;
    esac
    local repo_suffix="${version//./}"
    mrtk_log "configuring official Kamailio ${version}.x apt repository"
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates curl gnupg
    install -m 0755 -d /usr/share/keyrings
    rm -f /usr/share/keyrings/kamailio.gpg.tmp /usr/share/keyrings/kamailio.asc.tmp
    curl -fsSL -o /usr/share/keyrings/kamailio.asc.tmp https://deb.kamailio.org/kamailiodebkey.gpg
    gpg --batch --yes --dearmor -o /usr/share/keyrings/kamailio.gpg.tmp /usr/share/keyrings/kamailio.asc.tmp
    rm -f /usr/share/keyrings/kamailio.asc.tmp
    mv /usr/share/keyrings/kamailio.gpg.tmp /usr/share/keyrings/kamailio.gpg
    chmod 0644 /usr/share/keyrings/kamailio.gpg
    cat > /etc/apt/sources.list.d/kamailio.list <<EOF
deb [signed-by=/usr/share/keyrings/kamailio.gpg] http://deb.kamailio.org/kamailio${repo_suffix} ${codename} main
EOF
    cat > /etc/apt/preferences.d/kamailio <<'EOF'
Package: kamailio*
Pin: origin deb.kamailio.org
Pin-Priority: 1001

Package: kamcli
Pin: origin deb.kamailio.org
Pin-Priority: 1001
EOF
    apt-get update -y
  else
    local major="$MRTK_TELEPHONY_OS_MAJOR"
    mrtk_log "configuring official Kamailio ${version}.x yum repository"
    dnf install -y epel-release dnf-plugins-core ca-certificates curl
    rpm --import https://rpm.kamailio.org/rpm-pub.key
    cat > /etc/yum.repos.d/kamailio.repo <<EOF
[kamailio-${version}]
name=Kamailio ${version}.x official repository
baseurl=https://rpm.kamailio.org/rocky/${major}/${version}/${version}/\$basearch/
enabled=1
gpgcheck=1
gpgkey=https://rpm.kamailio.org/rpm-pub.key
EOF
    dnf clean all
    dnf makecache --repo "kamailio-${version}"
  fi
}

mrtk_install_kamailio_package() {
  mrtk_configure_kamailio_repository
  mrtk_detect_telephony_os
  local profile="${MNSCLOUD_KAMAILIO_PACKAGE_PROFILE:-core}"

  mrtk_log "installing Kamailio ${profile} packages"
  if [[ "$MRTK_TELEPHONY_OS_FAMILY" == "debian" ]]; then
    local apt_options=()
    mapfile -t apt_options < <(mrtk_apt_options)
    apt_options+=(
      -o Dpkg::Options::=--force-confdef
      -o Dpkg::Options::=--force-confold
    )
    if [[ "$profile" == "webrtc" ]]; then
      DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" install -y --no-install-recommends \
        kamailio kamailio-websocket-modules kamailio-tls-modules \
        kamailio-json-modules kamailio-utils-modules kamailio-extra-modules \
        kamailio-outbound-modules kamailio-presence-modules wireshark-common
    else
      DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" install -y --no-install-recommends \
        kamailio kamailio-extra-modules kamailio-utils-modules kamailio-tls-modules \
        kamailio-json-modules kamailio-outbound-modules sngrep tcpdump wireshark-common ngrep dnsutils iputils-ping traceroute \
        mtr-tiny netcat-openbsd jq ca-certificates curl
    fi
  else
    dnf install -y \
      kamailio kamailio-utils kamailio-json kamailio-curl kamailio-extra sngrep tcpdump wireshark-cli ngrep \
      bind-utils iputils traceroute mtr nc jq curl ca-certificates
  fi

  command -v kamailio >/dev/null 2>&1 || mrtk_die "Kamailio installation failed"
}

mrtk_ensure_kamailio() {
  mrtk_install_kamailio_package
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
  if command -v mariadbd >/dev/null 2>&1; then
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
