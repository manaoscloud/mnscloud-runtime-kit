# AGENTS.md

Runtime installer repository for common MNSCloud infrastructure dependencies.

## Scope

- Shared installation logic only.
- No module-specific service configuration.
- No secrets, customer data, private topology, internal policy, or product business rules.

## Supported Operating Systems

- Debian 12/13
- RHEL 9/10
- Rocky Linux 9/10
- AlmaLinux 9/10

## Git Workflow

- Validate shell syntax after changes.
- Commit and push completed changes.
- Keep public contribution governance files current.

## Release Workflow For Maintainers And AI Agents

- Production runtime-kit consumption is Git tag based.
- `main` is development/integration only.
- `VERSION` must match the intended semantic version without `v`.
- `releases/manifest.json` is the canonical update-discovery source for
  modules and automation.
- Publish a release by validating, committing, tagging `vX.Y.Z`, pushing
  `main`, and pushing the tag.
- Never update a consumer repo to a runtime-kit version until the matching tag
  exists on GitHub.
