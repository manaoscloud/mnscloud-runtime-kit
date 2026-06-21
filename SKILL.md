# MNSCloud Runtime Kit Skill

Use this repository to maintain shared, public-safe runtime installers consumed by autonomous
MNSCloud service modules.

## Rules

- Keep business logic, tenant policy, service routes, secrets, private domains, and customer data out
  of this repository.
- Prefer official upstream repositories for runtime packages when the MNSCloud module contract
  requires them.
- Centralize host-level package repository setup for shared runtimes here, including Nginx,
  Flutter, Deno, Node.js, Docker, Certbot, RabbitMQ/Erlang, Asterisk build dependencies,
  FreeSWITCH, OpenSIPS, Kamailio, coturn, basic-auth utilities, and MariaDB.
- Keep installers idempotent: rerunning a script should converge, not duplicate work.
- Support only documented operating systems unless the validation matrix is extended in the same
  change.
- When adding or changing an installer, update `README.md`, `config/manifests/stable.env`, and CI
  syntax validation.
- Production consumers must pin Git tags. `main` is development-only.
- `VERSION` and `releases/manifest.json` are the release-discovery contract.
- Do not update consumers to a runtime-kit ref until the matching release commit,
  Git tag, and GitHub Release exist on GitHub.
- Operator-visible runtime-kit releases are published by the repository
  `Release` GitHub Actions workflow after validated changes are committed and
  pushed to `main`.
- `scripts/release-runtime-kit.sh --version X.Y.Z --channel stable --publish`
  is the canonical release engine used by Actions and is reserved for
  break-glass maintainer use.
- Use the shared `lib/release.sh` helper for release scripts in consumer repositories; do not copy
  per-repository release logic.
- When a consumer publishes deployable artifacts, write `channels.<channel>.artifact` in
  `releases/manifest.json` during validation and use `--asset-glob` so the GitHub Release carries
  the exact artifact consumed by runtime hosts. Runtime hosts should download and checksum-verify
  artifacts instead of rebuilding source code.

## Validation

```bash
bash -n scripts/*.sh lib/*.sh installers/*.sh
./scripts/doctor.sh --help
```
