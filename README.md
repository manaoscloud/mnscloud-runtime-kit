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

This kit may install shared runtimes such as Nginx, Flutter, Deno, Node.js, Docker, and MariaDB. It
must not contain customer data, production domains, private topology, API secrets, billing rules,
tenant policy, PABX credentials, or module-specific application configuration.

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
- `mariadb`: configures the official MariaDB repository for `MNSCLOUD_MARIADB_VERSION` and installs
  MariaDB server/client/backup packages plus Galera where the OS packaging uses a separate package.

## Install A Tool

```bash
sudo ./scripts/install-tool.sh --tool nginx
sudo ./scripts/install-tool.sh --tool flutter
sudo MNSCLOUD_DENO_VERSION=2.8.1 ./scripts/install-tool.sh --tool deno
sudo MNSCLOUD_NODE_MAJOR_VERSION=24 ./scripts/install-tool.sh --tool nodejs
sudo ./scripts/install-tool.sh --tool docker
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
- Update a consumer only after the matching runtime-kit Git tag has been pushed.
- Keep module-specific service configuration and business behavior in the
  consumer repository.

## Maintainer Release Flow

Only maintainers should publish production runtime-kit releases:

```bash
cd /opt/mnscloud/mnscloud-runtime-kit
scripts/release-runtime-kit.sh --version 0.1.7 --channel stable
git push origin main
git push origin v0.1.7
gh release create v0.1.7 --title "mnscloud-runtime-kit v0.1.7" --generate-notes
```

AI coding agents must follow the same flow: update installer code, validate,
update `VERSION` and `releases/manifest.json`, commit, tag, push `main`, and
push the tag. Do not update consumers to a runtime-kit ref until that tag exists
on GitHub.
