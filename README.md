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

## apt/dpkg locks

Every apt call in `lib/packages.sh` goes through `mrtk_apt_get` (`lib/apt.sh`). Right after
boot, `unattended-upgrades`/apt-daily often hold the dpkg or apt lists lock, and plain
`apt-get` fails immediately with exit 100. `mrtk_apt_get` first waits for those locks
(checked with `lslocks`, logging progress every 30s) and gives installs
`DPkg::Lock::Timeout` through a transient `APT_CONFIG`, so `/etc/apt` is never changed.
The wait defaults to 600 seconds; override it with `MNSCLOUD_APT_LOCK_TIMEOUT`. When the
wait expires, apt-get still runs so its error names the lock holder.

## Boundary

This kit may install shared runtimes such as Nginx, Flutter, Deno, Node.js, Docker, Certbot,
RabbitMQ/Erlang, OpenBao, Asterisk build dependencies, FreeSWITCH, OpenSIPS, Kamailio, coturn, and MariaDB. It must not contain customer data, production domains, private topology, API secrets,
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
- `openbao`: downloads the official OpenBao release binary, verifies it with the published
  checksum, and installs the `bao` CLI/server binary. OpenBao service configuration remains owned by
  the consuming module.
- `asterisk-build-deps`: installs Debian dependencies required to build the MNSCloud Asterisk
  runtime from upstream Asterisk source. Asterisk source compilation remains owned by the consumer.
- `freeswitch`: configures the official SignalWire FreeSWITCH repository using the supplied token
  and installs the package set used by the MNSCloud FreeSWITCH runtime.
- `opensips`: configures the official OpenSIPS package repository and installs the MNSCloud SBC
  package set.
- `kamailio`: configures the official Kamailio package repository and installs either the core or
  WebRTC package set, selected by `MNSCLOUD_KAMAILIO_PACKAGE_PROFILE`.
- `freeradius`: installs the network authentication engine and MariaDB client from signed OS repositories; requires version 3.2.5 or newer and fails closed on older distribution packages.
- `clickhouse`: installs the log storage engine (server, client) from the official ClickHouse LTS APT repository, signed key pinned by fingerprint `3A9EA119…2B48D754`, held to the homologated series `MNSCLOUD_CLICKHOUSE_SERIES` (default `26.3`, x86-64-v2). Debian 12/13 only. The installer checks the CPU level the series needs: x86-64-v2 (SSE4.2/POPCNT) up to 26.5, x86-64-v3 (AVX2, BMI1/2, FMA, MOVBE, F16C) from 26.6, whose official x86 builds dropped older CPUs; arm64 always passes. Installs non-interactively; the package still prompts on a terminal for a default-user password unless one is configured, so consumers pre-create `users.d/default-password.xml` (the Logs runtime uses a discarded random hash). The package postinst runs `systemctl enable clickhouse-server`, which fails on a masked unit: do not mask it before installing. 26.3 receives fixes until about March 2027 (one-year LTS policy): move to AVX2 hosts or a compatibility build of the next LTS before then. Does not start or configure the service.
- `vector`: installs the log ingest gateway from the official Vector APT repository (Datadog key `5F1E2560…E6266D4AC0962C7D`, expires 2028-04-19), held to `MNSCLOUD_VECTOR_SERIES` (default `0.59`). Debian 12/13 only. Does not configure the service.
- `pdns-auth`, `pdns-recursor`, `dnsdist`: install the DNS engines of the DNS module (PowerDNS Authoritative with the LMDB backend, PowerDNS Recursor, dnsdist) from the official `repo.powerdns.com` release trains, signed key pinned by fingerprint `9FAAA557…1B0C6205FD380FBB` (PowerDNS Release Signing Key), each held to its homologated series (`MNSCLOUD_PDNS_AUTH_SERIES` default `5.1`, `MNSCLOUD_PDNS_RECURSOR_SERIES` default `5.4`, `MNSCLOUD_DNSDIST_SERIES` default `2.1`) so the older Debian packages never replace them. Debian 12/13 on amd64 or arm64 (64-bit Raspberry Pi OS included). Packages are installed behind a deny-all `policy-rc.d` (unless one already exists), so no service starts with the packaged configuration; the consumer writes its configuration and starts the units.
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
sudo MNSCLOUD_OPENBAO_VERSION=2.6.2 ./scripts/install-tool.sh --tool openbao
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
updates the DB-backed runtime release cache. The `buildRef` is the full 40-character
commit resolved from the published tag, so installers can verify immutable source.

The shared workflow publishes release metadata to the control plane. After synchronizing the
release cache, the API queues the Agent-backed runtime rollout from the same release publish
request:

- `MNSCLOUD_RELEASE_SYNC_URL`: control-plane base URL.
- `MNSCLOUD_RELEASE_SYNC_TOKEN`: bearer token accepted by the API release sync endpoint.

The API queues the product rollout for supported Agent-managed runtimes. Products outside the Agent
runtime catalog are not included; database rollout remains outside this helper.

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

Static web clients (for example `mnscloud-phoneweb`, `mnscloud-pulse`, and `mnscloud-website`)
use `scripts/package-static-artifact.sh` as a release validation step. It archives the built
directory (Flutter `build/web`, Astro `dist/`, ...) with the files at the archive root, writes a
`<name>.sha256` sidecar, and records the `artifact` metadata above. Upload both files with
`mrtk_release_prepare --asset-glob` and never commit them:

```bash
export MNSCLOUD_RUNTIME_KIT_DIR="$RUNTIME_KIT_DIR"
mrtk_release_prepare ... \
  --validate 'flutter build web --release --base-href /' \
  --validate '"$MNSCLOUD_RUNTIME_KIT_DIR/scripts/package-static-artifact.sh" --source-dir build/web --name "mnscloud-demo-web-v$(cat VERSION).tar.gz"' \
  --asset-glob 'releases/mnscloud-demo-web-v*.tar.gz*'
```

Repositories that build with Flutter in the release job set `setup_flutter: true` on the shared
`auto-release.yml` workflow; the Flutter version comes from `toolchains/flutter.json` (section
Flutter clients). `flutter_version` overrides it only for a break-glass rebuild.

Repositories whose `main` is protected (pull request and status checks required) set
`tag_only: true`: the release commit (VERSION, manifest) is pushed only as the annotated tag, never to
`main`, and the next patch version comes from the latest `vX.Y.Z` tag instead of `VERSION`.

Use `--asset-glob` in the repository release script to upload those files to the GitHub Release.
The shared workflow derives the final HTTPS asset URL from the release tag and sends URL, SHA-256,
size, and content type to the MNSCloud runtime release cache. Runtime hosts must download and verify
that artifact instead of rebuilding source code locally.

## Flutter clients

Shared toolchain, CI and PWA contract of every MNSCloud Flutter client (PhoneWeb, Pulse, POS,
InfraGIS Mobile and new ones). The workspace contract that tells when to use each piece is
`docs/flutter-client-standard.md` in `manaoscloud/mnscloud`.

- **Toolchain.** `toolchains/flutter.json` pins the latest Flutter stable. `auto-release.yml`,
  `sonarcloud-dart.yml` and `flutter-client-ci.yml` install exactly that version
  (`scripts/flutter-toolchain.py get flutter`), so a rebuild of a tag is reproducible. The weekly
  `flutter-toolchain-bump.yml` workflow compares it with the newest stable, validates the four
  clients against it (pub get, analyze, test, web build) and proposes the bump on the branch
  `chore/flutter-toolchain-<x-y-z>` (pull request, or an issue where Actions may not open pull
  requests). Merge it with `scripts/ops/merge.sh`; clients pick it up on their next run.
- **CI.** `.github/workflows/flutter-client-ci.yml` (inputs `targets`, `web_mode`, `web_check`,
  `native_check_args`, `linux_packages`, `apple`) runs analyze, test, the native configuration
  check and one build per declared target. Apple builds need `apple: true` (macOS runners).
- **Native configuration.** `scripts/check-flutter-native.py` fails when a release build could
  not reach the network or a declared device: `INTERNET` in the main Android manifest,
  `network.client` in both macOS entitlements, extra permissions, entitlements and Info.plist
  keys, and iOS 15 / macOS 12 minimum deployment targets.
- **PWA.** Flutter no longer ships a caching service worker (3.47 writes a self-unregistering
  stub). After `flutter build web --release --base-href / --no-web-resources-cdn`, run:

  ```bash
  python3 "$MNSCLOUD_RUNTIME_KIT_DIR/scripts/flutter-pwa.py" generate --build-dir build/web --app <app>
  python3 "$MNSCLOUD_RUNTIME_KIT_DIR/scripts/flutter-pwa.py" validate --build-dir build/web --base-href /
  ```

  `generate` writes `sw.js` from `templates/pwa/sw.js`:
  - It precaches the app shell of the build plus the CanvasKit variant the browser loads, and
    serves one revision atomically (cache first). The old revision stays until the app applies the
    update.
  - It never caches `/api/`, `build.json`, `update-policy.json` or `version.json`, and it ignores
    anything outside its scope.
  - It caches `https://fonts.gstatic.com` on first use. Pass `--runtime-origin` for other https
    origins.

  `generate` also removes the deprecated Flutter worker registration from `flutter_bootstrap.js`
  and appends `templates/pwa/register.js`, which exposes:
  - `window.mnscloudPwa.applyUpdate()`: the "Update now" action of the new-version notice
    (activates the waiting revision, then reloads);
  - `window.mnscloudPwa.persistStorage()`.

  `validate` checks the manifest (relative `id`/`scope`/`start_url`, display, 192/512 and maskable
  icons), `index.html` (base href, manifest link, viewport, theme-color), the worker and the local
  CanvasKit. The web build stays portable: `mnscloud-webapps` rewrites only `<base href>`, and the
  worker scope follows it.

## Local configuration reconciliation primitives

`lib/env_reconcile.py` supplies Linux-only Python 3 primitives for release-owned adapters.
It is a library, not a remotely callable configuration editor. The adapter owns fixed paths,
field rules, validation, Agent assignment/lease checks, and service activation/recovery.
No network requests or service commands are executed by the library.

Supported operations are initialize-if-empty (conflicting existing values are rejected),
three-way managed values with an explicit baseline, optional managed values
(`managed-optional`: same baseline check, and an empty desired value removes the key), and
additive comma-separated sets.
Unknown fields/comments are preserved. Only a deliberately restricted single-line literal
subset of environment syntax is accepted; unsupported quotes, expansions in managed values,
multiline values, duplicate managed fields and ambiguous files fail closed.

Create a private local journal directory before using `EnvJournal.stage()` and `apply()`.
Paths must be absolute, with no symlink or group/world-writable ancestors; directories and
files must belong to the executing account. Production adapters run as root. Existing
configuration files are required: bootstrap file creation is deliberately not provided.
Plans contain the before-image and candidate, including secrets, and stay local with mode
0600 in a 0700 directory. Never upload a journal, log it or put it into an Agent result.
Plan operation IDs are immutable. Adapters must implement bounded journal retention after
verified service activation; do not remove an unverified recovery journal.

The library locks cooperating executors, checks content/metadata before replacement, writes
and fsyncs a temporary file, atomically replaces the destination, and fsyncs its directory.
A crash after replacement is recovered by reading actual contents, without a second write.
`apply().changed` describes a write in that invocation, not service readiness. It cannot
establish that a prior activation succeeded: adapters must journal and verify activation
separately. The library never claims multi-file atomicity, service rollback, or exclusion of
an unrelated privileged process that ignores the lock. Remote leases, fencing, rollout
barriers and secret delivery remain control-plane/adapter responsibilities.

Run `python3 -m unittest discover -s tests -v` for conflict, retry, crash, lock, permissions,
path safety and preservation tests. There is no Windows implementation in this library.
