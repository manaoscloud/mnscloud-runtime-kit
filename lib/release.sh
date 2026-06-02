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

The helper updates VERSION and releases/manifest.json, runs validations, commits release metadata,
creates an annotated semver tag, and optionally publishes the GitHub Release.
EOF
}

mrtk_release_prepare() {
  local product=""
  local repository=""
  local version=""
  local channel="stable"
  local minimum_version=""
  local sync_package_json="0"
  local publish="0"
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
    return 0
  fi

  mrtk_release_log "publish with:"
  mrtk_release_log "git push origin main"
  mrtk_release_log "git push origin ${tag}"
  mrtk_release_log "gh release create ${tag} --repo ${repository} --title \"${product} ${tag}\" --generate-notes"
}
