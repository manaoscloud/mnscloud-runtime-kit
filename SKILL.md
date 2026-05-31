# MNSCloud Runtime Kit Skill

Use this repository to maintain shared, public-safe runtime installers consumed by autonomous
MNSCloud service modules.

## Rules

- Keep business logic, tenant policy, service routes, secrets, private domains, and customer data out
  of this repository.
- Prefer official upstream repositories for runtime packages when the MNSCloud module contract
  requires them.
- Keep installers idempotent: rerunning a script should converge, not duplicate work.
- Support only documented operating systems unless the validation matrix is extended in the same
  change.
- When adding or changing an installer, update `README.md`, `config/manifests/stable.env`, and CI
  syntax validation.
- Production consumers must pin Git tags. `main` is development-only.
- `VERSION` and `releases/manifest.json` are the release-discovery contract.
- Do not update consumers to a runtime-kit ref until the matching tag has been
  pushed to GitHub.
- Use `scripts/release-runtime-kit.sh --version X.Y.Z --channel stable` to
  prepare a release.

## Validation

```bash
bash -n scripts/*.sh lib/*.sh installers/*.sh
./scripts/doctor.sh --help
```
