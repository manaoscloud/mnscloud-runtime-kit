# mnscloud-runtime-kit

Shared runtime installers for MNSCloud infrastructure modules.

This repository centralizes operating-system detection and installation of common runtimes used by
autonomous MNSCloud modules. It keeps package repository setup, validated installation steps, and
repeatable checks in one public place while each product module remains responsible for its own
service configuration and business behavior.

## Contract

- Product/runtime: `mnscloud-runtime-kit`
- Default install directory: `/opt/mnscloud/runtime-kit`
- Supported operating systems:
  - Debian 12/13
  - RHEL 9/10
  - Rocky Linux 9/10
  - AlmaLinux 9/10

## Boundary

This kit may install shared runtimes such as Nginx, Flutter, Deno, Node.js, Docker, Certbot,
RabbitMQ/Erlang, Asterisk build dependencies, FreeSWITCH, OpenSIPS, Kamailio, and MariaDB. It must not contain customer data, production domains, private topology, API secrets,
billing rules, tenant policy, PABX credentials, or module-specific application configuration.

Modules consume this kit for the question: "How do we install runtime X safely on this OS?"

Modules still own the question: "How does my service use runtime X?"

## Tools

Current installers:

- `nginx`: configures the official stable `nginx.org` repository and installs `nginx`.
- `flutter`: installs Flutter build dependencies from the OS package manager, clones/updates the
  Flutter SDK from the official Flutter GitHub repository, and exposes `flutter` and `dart`.
  The default build profile is `web`, which keeps server dependencies lean for static web bundles.
- `deno`: installs the pinned Deno runtime version with the official `deno.land` installer and
  exposes `deno` in `/usr/local/bin`.
- `nodejs`: configures the official NodeSource repository for `MNSCLOUD_NODE_MAJOR_VERSION` and
  installs Node.js with npm.
- `docker`: configures the official Docker repository and installs Docker Engine plus the Compose
  plugin.
- `certbot`: removes any old OS-packaged Certbot install, installs Certbot with the
  upstream-recommended Snap package, and enables the renewal timer when available.
- `rabbitmq`: configures the official Team RabbitMQ repositories for RabbitMQ and Erlang/OTP, then
  installs `rabbitmq-server` with Erlang packages. RabbitMQ service configuration remains owned by
  the consuming module.
- `asterisk-build-deps`: installs Debian dependencies required to build the MNSCloud Asterisk
  runtime from upstream Asterisk source. Asterisk source compilation remains owned by the consumer.
- `freeswitch`: configures the official SignalWire FreeSWITCH repository using the supplied token
  and installs the package set used by the MNSCloud FreeSWITCH runtime.
- `opensips`: configures the official OpenSIPS package repository and installs the MNSCloud SBC
  package set.
- `kamailio`: configures the official Kamailio package repository and installs either the core or
  WebRTC package set, selected by `MNSCLOUD_KAMAILIO_PACKAGE_PROFILE`.
- `basic-auth-utils`: installs the `htpasswd` utility used by edge/admin proxy modules.
- `mariadb`: configures the official MariaDB repository for `MNSCLOUD_MARIADB_VERSION` and installs
  MariaDB server/client/backup packages plus Galera where the OS packaging uses a separate package.

## Install A Tool

```bash
sudo ./scripts/install-tool.sh --tool nginx
sudo ./scripts/install-tool.sh --tool flutter
sudo MNSCLOUD_DENO_VERSION=2.8.1 ./scripts/install-tool.sh --tool deno
sudo MNSCLOUD_NODE_MAJOR_VERSION=24 ./scripts/install-tool.sh --tool nodejs
sudo ./scripts/install-tool.sh --tool docker
sudo ./scripts/install-tool.sh --tool certbot
sudo ./scripts/install-tool.sh --tool rabbitmq
sudo ./scripts/install-tool.sh --tool asterisk-build-deps
sudo MNSCLOUD_FREESWITCH_SIGNALWIRE_TOKEN=... ./scripts/install-tool.sh --tool freeswitch
sudo ./scripts/install-tool.sh --tool opensips
sudo MNSCLOUD_KAMAILIO_PACKAGE_PROFILE=webrtc ./scripts/install-tool.sh --tool kamailio
sudo ./scripts/install-tool.sh --tool basic-auth-utils
sudo MNSCLOUD_MARIADB_VERSION=12.3 ./scripts/install-tool.sh --tool mariadb
```

For hosts that also need Linux desktop builds, use:

```bash
sudo MNSCLOUD_FLUTTER_BUILD_PROFILE=linux ./scripts/install-tool.sh --tool flutter
```

To avoid running Flutter itself as root from a root installer, provide an existing service user:

```bash
sudo MNSCLOUD_FLUTTER_RUN_USER=mnscloud-webapps ./scripts/install-tool.sh --tool flutter
```

## Doctor

```bash
sudo ./scripts/doctor.sh
sudo ./scripts/doctor.sh --tool nginx
sudo ./scripts/doctor.sh --tool flutter
sudo ./scripts/doctor.sh --tool deno
sudo ./scripts/doctor.sh --tool nodejs
sudo ./scripts/doctor.sh --tool docker
sudo ./scripts/doctor.sh --tool certbot
sudo ./scripts/doctor.sh --tool rabbitmq
sudo ./scripts/doctor.sh --tool asterisk
sudo ./scripts/doctor.sh --tool freeswitch
sudo ./scripts/doctor.sh --tool opensips
sudo ./scripts/doctor.sh --tool kamailio
sudo ./scripts/doctor.sh --tool basic-auth-utils
sudo ./scripts/doctor.sh --tool mariadb
```

## Runtime Pinning

Production modules should pin this repository by an explicit Git ref. A module installer can clone
or update this kit and source the shared libraries from that pinned ref.

Example:

```bash
MNSCLOUD_RUNTIME_KIT_REF=v1.0.0
```

Use `main` only for development environments.

## Release Discovery Contract

Canonical release metadata lives in [`releases/manifest.json`](./releases/manifest.json).

MNSCloud modules and automation must use this contract:

- Treat `main` as development only.
- Treat `channels.<channel>.ref` as the production runtime-kit target.
- Pin consumers with `MNSCLOUD_RUNTIME_KIT_REF` or their module-specific
  variable, such as `API_RUNTIME_KIT_REF`, `APP_RUNTIME_KIT_REF`,
  `DB_RUNTIME_KIT_REF`, or `AGENT_RUNTIME_KIT_REF`.
- Update a consumer only after the matching runtime-kit Git tag and GitHub Release have been
  pushed.
- Keep module-specific service configuration and business behavior in the
  consumer repository.

## Maintainer Release Flow

Only maintainers should publish production runtime-kit releases:

```bash
cd /opt/mnscloud/mnscloud-runtime-kit
scripts/release-runtime-kit.sh --version 0.1.7 --channel stable --publish
```

AI coding agents must follow the same flow: update installer code, validate,
update `VERSION` and `releases/manifest.json`, commit, tag, push `main`, push
the tag, and create the GitHub Release. Do not update consumers to a runtime-kit
ref until that tag and GitHub Release exist on GitHub.
