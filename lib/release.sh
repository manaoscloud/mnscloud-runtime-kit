#!/usr/bin/env bash

mrtk_release_log() {
  local product="${MRTK_RELEASE_PRODUCT:-mnscloud-release}"
  printf '[%s] %s\n' "$product" "$*"
}

mrtk_release_die() {
  local product="${MRTK_RELEASE_PRODUCT:-mnscloud-release}"
  printf '[%s] ERROR: %s\n' "$product" "$*" >&2
  exit 1
}

mrtk_release_usage() {
  cat <<'EOF'
Usage:
  mrtk_release_prepare --product <name> --repository <owner/repo> --version <x.y.z> [options]

Options:
  --channel <stable|candidate>      Release channel. Default: stable.
  --minimum-version <x.y.z>         Default minimumVersion when a channel is created.
  --validate <command>              Validation command. May be repeated.
  --add-path <path>                 Extra git path to include in the release commit. May be repeated.
  --sync-package-json               Sync package.json and package-lock.json root versions.
  --publish                         Push main + tag and create the GitHub Release with gh.
  --skip-db-sync                    Do not sync the published release into the MNSCloud DB cache.

The helper updates VERSION and releases/manifest.json, runs validations, commits release metadata,
creates an annotated semver tag, optionally publishes the GitHub Release, and syncs the release
cache through ProcMonitoringAgentReleasePublish when workspace DB credentials are available.
EOF
}

mrtk_release_sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

mrtk_release_db_env_file() {
  local candidate
  for candidate in \
    "${MNSCLOUD_WORKSPACE_ENV_FILE:-}" \
    "/etc/mnscloud/workspace.env"; do
    [[ -n "$candidate" && -r "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

mrtk_release_sync_db() {
  local product="$1" channel="$2" version="$3" tag="$4" released_at="$5"

  [[ "${MNSCLOUD_RELEASE_DB_SYNC:-1}" != "0" ]] || {
    mrtk_release_log "release DB sync disabled by MNSCLOUD_RELEASE_DB_SYNC=0"
    return 0
  }

  command -v mariadb >/dev/null 2>&1 || {
    mrtk_release_log "release DB sync skipped: mariadb client not found"
    return 0
  }

  local env_file
  env_file="$(mrtk_release_db_env_file)" || {
    mrtk_release_log "release DB sync skipped: workspace env file not found"
    return 0
  }

  # shellcheck disable=SC1090
  set -a
  source "$env_file"
  set +a

  local host="${DB_HOST:-}" port="${DB_PORT:-3306}" db="${DB_NAME:-}"
  local user="${DB_MIGRATION_USER:-${DB_USER:-}}" pass="${DB_MIGRATION_PASS:-${DB_PASS:-}}"
  [[ -n "$host" && -n "$db" && -n "$user" ]] || {
    mrtk_release_log "release DB sync skipped: DB_HOST/DB_NAME/DB_USER are not configured"
    return 0
  }

  local build_ref
  build_ref="$(git rev-list -n 1 "$tag" | cut -c1-12)"
  [[ -n "$build_ref" ]] || mrtk_release_die "could not resolve release commit for ${tag}"

  local build_date
  build_date="$(printf "%s" "$released_at" | sed 's/T/ /; s/Z$//; s/[.][0-9][0-9][0-9]$//')"
  [[ -n "$build_date" ]] || build_date="$(git log -1 --format='%cI' "$tag" | sed 's/T/ /; s/[+-][0-9][0-9]:[0-9][0-9]$//')"

  local defaults_file sql_file
  defaults_file="$(mktemp)"
  sql_file="$(mktemp)"
  chmod 0600 "$defaults_file" "$sql_file"
  {
    printf '[client]\n'
    printf 'host=%s\n' "$host"
    printf 'port=%s\n' "$port"
    printf 'user=%s\n' "$user"
    printf 'database=%s\n' "$db"
    if [[ -n "$pass" ]]; then
      printf 'password=%s\n' "$pass"
    fi
  } > "$defaults_file"
  cat > "$sql_file" <<SQL
CALL ProcMonitoringAgentReleasePublish(
  '$(mrtk_release_sql_escape "$product")',
  '$(mrtk_release_sql_escape "$channel")',
  '$(mrtk_release_sql_escape "$version")',
  '$(mrtk_release_sql_escape "$build_ref")',
  '$(mrtk_release_sql_escape "$build_date")',
  'Synced by mnscloud-runtime-kit release helper from ${tag}.'
);
SQL

  mrtk_release_log "syncing release cache in DB: ${product} ${tag} (${build_ref})"
  if ! mariadb --defaults-extra-file="$defaults_file" < "$sql_file"; then
    rm -f "$defaults_file" "$sql_file"
    mrtk_release_die "release DB sync failed for ${product} ${tag}"
  fi
  rm -f "$defaults_file" "$sql_file"
}

mrtk_release_prepare() {
  local product=""
  local repository=""
  local version=""
  local channel="stable"
  local minimum_version=""
  local sync_package_json="0"
  local publish="0"
  local skip_db_sync="0"
  local -a validations=()
  local -a add_paths=("VERSION" "releases/manifest.json")

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --product) product="${2:-}"; shift 2 ;;
      --repository) repository="${2:-}"; shift 2 ;;
      --version) version="${2:-}"; shift 2 ;;
      --channel) channel="${2:-}"; shift 2 ;;
      --minimum-version) minimum_version="${2:-}"; shift 2 ;;
      --validate) validations+=("${2:-}"); shift 2 ;;
      --add-path) add_paths+=("${2:-}"); shift 2 ;;
      --sync-package-json) sync_package_json="1"; shift ;;
      --publish) publish="1"; shift ;;
      --skip-db-sync) skip_db_sync="1"; shift ;;
      --help|-h) mrtk_release_usage; return 0 ;;
      *) mrtk_release_die "unknown argument: $1" ;;
    esac
  done

  MRTK_RELEASE_PRODUCT="${product:-mnscloud-release}"

  [[ -n "$product" ]] || { mrtk_release_usage; mrtk_release_die "--product is required"; }
  [[ -n "$repository" ]] || { mrtk_release_usage; mrtk_release_die "--repository is required"; }
  [[ "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
    { mrtk_release_usage; mrtk_release_die "invalid semantic version: ${version:-empty}"; }
  [[ "$channel" =~ ^(stable|candidate)$ ]] || mrtk_release_die "invalid channel: $channel"

  [[ -z "$(git status --short)" ]] || mrtk_release_die "working tree must be clean before release"

  local tag="v${version}"
  if git remote get-url origin >/dev/null 2>&1; then
    git fetch --tags --prune origin
  fi
  git rev-parse --verify --quiet "refs/tags/${tag}" >/dev/null &&
    mrtk_release_die "tag already exists: ${tag}"

  printf '%s\n' "$version" > VERSION

  if [[ "$sync_package_json" == "1" ]]; then
    deno eval '
const version = Deno.args[0];
for (const file of ["package.json", "package-lock.json"]) {
  try {
    const data = JSON.parse(await Deno.readTextFile(file));
    data.version = version;
    if (data.packages?.[""]) data.packages[""].version = version;
    await Deno.writeTextFile(file, `${JSON.stringify(data, null, 2)}\n`);
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) continue;
    throw error;
  }
}
' "$version"
    add_paths+=("package.json" "package-lock.json")
  fi

  mkdir -p releases
  deno eval '
const [manifestPath, product, repository, channel, version, minimumVersion] = Deno.args;
const now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
const raw = await Deno.readTextFile(manifestPath).catch(() => "{}");
const manifest = raw.trim() ? JSON.parse(raw) : {};
manifest.product = product;
manifest.repository = repository;
manifest.channels ??= {};
const previous = manifest.channels[channel] ?? {};
const next = {
  ...previous,
  version,
  ref: `v${version}`,
  releasedAt: now,
};
if (!("minimumVersion" in next) && minimumVersion) {
  next.minimumVersion = minimumVersion;
}
manifest.channels[channel] = next;
await Deno.writeTextFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
' releases/manifest.json "$product" "$repository" "$channel" "$version" "$minimum_version"

  local released_at
  released_at="$(deno eval '
const [manifestPath, channel] = Deno.args;
const manifest = JSON.parse(await Deno.readTextFile(manifestPath));
console.log(manifest.channels?.[channel]?.releasedAt ?? "");
' releases/manifest.json "$channel")"

  local validation
  for validation in "${validations[@]}"; do
    mrtk_release_log "validating: ${validation}"
    bash -o pipefail -c "$validation"
  done

  git add "${add_paths[@]}"
  git commit -m "Release ${product} ${tag}"
  git tag -a "$tag" -m "Release ${product} ${tag}"
  mrtk_release_log "release metadata committed and tag created: ${tag}"

  if [[ "$publish" == "1" ]]; then
    command -v gh >/dev/null 2>&1 ||
      mrtk_release_die "gh is required for --publish"
    git push origin main
    git push origin "$tag"
    if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
      mrtk_release_log "GitHub Release already exists: ${tag}"
    else
      gh release create "$tag" --repo "$repository" --title "${product} ${tag}" --generate-notes
    fi
    if [[ "$skip_db_sync" != "1" ]]; then
      mrtk_release_sync_db "$product" "$channel" "$version" "$tag" "$released_at"
    fi
    return 0
  fi

  mrtk_release_log "publish with:"
  mrtk_release_log "git push origin main"
  mrtk_release_log "git push origin ${tag}"
  mrtk_release_log "gh release create ${tag} --repo ${repository} --title \"${product} ${tag}\" --generate-notes"
  if [[ "$skip_db_sync" != "1" ]]; then
    mrtk_release_log "after publishing, sync DB cache with this helper or rerun with --publish"
  fi
}
