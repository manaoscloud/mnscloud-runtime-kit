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
RabbitMQ/Erlang, Asterisk build dependencies, FreeSWITCH, OpenSIPS, Kamailio, coturn, and MariaDB. It must not contain customer data, production domains, private topology, API secrets,
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
- `coturn`: installs coturn and supporting utilities for dedicated TURN/STUN media edge modules.
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
sudo ./scripts/install-tool.sh --tool coturn
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

Production runtime-kit releases are published by GitHub Actions. Maintainers and
AI coding agents should update installer code, validate, commit, and push to
`main`; the repository `Release` workflow increments the patch version, updates
`VERSION` and `releases/manifest.json`, creates the release commit, tags it, and
publishes the GitHub Release.

Do not update consumers to a runtime-kit ref until the matching release commit,
Git tag, and GitHub Release exist on GitHub. The local
`scripts/release-runtime-kit.sh` script remains the canonical release engine used
by Actions and should be run manually only as a break-glass maintainer operation.

Runtime release discovery is synchronized by GitHub Actions through the
MNSCloud API. Direct database release sync is not part of the release helper.
Configure repository or organization secrets/variables:

- `MNSCLOUD_RELEASE_SYNC_URL`: control-plane base URL, for example
  `https://dev.example.com` or `https://dev.example.com/api/v1`.
- `MNSCLOUD_RELEASE_SYNC_TOKEN`: bearer token accepted by the API release sync
  endpoint.

After publishing the GitHub Release, the shared workflow posts the release
metadata to `/api/v1/runtime/releases/publish`; the API validates the token and
updates the DB-backed runtime release cache.

Repositories that publish deployable artifacts, such as `mnscloud-app`, must add artifact metadata
under `channels.<channel>.artifact` in `releases/manifest.json` during the release validation step:

```json
{
  "name": "mnscloud-app-browser-v0.1.0.tar.gz",
  "sha256": "<64-character sha256>",
  "sizeBytes": 123456,
  "contentType": "application/gzip"
}
```

Use `--asset-glob` in the repository release script to upload those files to the GitHub Release.
The shared workflow derives the final HTTPS asset URL from the release tag and sends URL, SHA-256,
size, and content type to the MNSCloud runtime release cache. Runtime hosts must download and verify
that artifact instead of rebuilding source code locally.
