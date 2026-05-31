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

This kit may install shared runtimes such as Nginx, Flutter, Deno, and MariaDB. It must not contain
customer data, production domains, private topology, API secrets, billing rules, tenant policy, PABX
credentials, or module-specific application configuration.

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
- `mariadb`: configures the official MariaDB repository for `MNSCLOUD_MARIADB_VERSION` and installs
  MariaDB server/client/backup packages plus Galera where the OS packaging uses a separate package.

## Install A Tool

```bash
sudo ./scripts/install-tool.sh --tool nginx
sudo ./scripts/install-tool.sh --tool flutter
sudo MNSCLOUD_DENO_VERSION=2.8.1 ./scripts/install-tool.sh --tool deno
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
