#!/usr/bin/env bash
# Shared retention helper for MNSCloud runtime products. Source it; it has no side effects.
#
#   mrtk_retention_prune ROOT NAME_REGEX KEEP MIN_AGE_DAYS [--protect NAME]... [--dry-run]
#
# Prints exactly one JSON line on stdout; messages go to stderr. Returns 0 on success and 2 on
# invalid arguments or ROOT. Requires GNU find, sort, du and rm.

_mrtk_retention_json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

mrtk_retention_prune() {
  if [ "$#" -lt 4 ]; then
    echo "mrtk_retention_prune: usage: ROOT NAME_REGEX KEEP MIN_AGE_DAYS [--protect NAME]... [--dry-run]" >&2
    return 2
  fi
  local root=$1 regex=$2 keep=$3 min_age=$4
  shift 4

  local -a protect=()
  local dry_run=false
  while [ "$#" -gt 0 ]; do
    case $1 in
      --protect)
        if [ "$#" -lt 2 ]; then
          echo "mrtk_retention_prune: --protect needs a NAME" >&2
          return 2
        fi
        protect+=("$2")
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      *)
        echo "mrtk_retention_prune: unknown argument: $1" >&2
        return 2
        ;;
    esac
  done

  case $keep in
    '' | *[!0-9]*)
      echo "mrtk_retention_prune: KEEP must be an integer >= 1: $keep" >&2
      return 2
      ;;
  esac
  case $min_age in
    '' | *[!0-9]*)
      echo "mrtk_retention_prune: MIN_AGE_DAYS must be an integer >= 0: $min_age" >&2
      return 2
      ;;
  esac
  keep=$((10#$keep))
  min_age=$((10#$min_age))
  if [ "$keep" -lt 1 ]; then
    echo "mrtk_retention_prune: KEEP must be an integer >= 1: $keep" >&2
    return 2
  fi

  case $root in
    /*) ;;
    *)
      echo "mrtk_retention_prune: ROOT must be an absolute path: $root" >&2
      return 2
      ;;
  esac
  # Strip trailing slashes; a ROOT made only of slashes is "/".
  while [ "${#root}" -gt 1 ] && [ "${root%/}" != "$root" ]; do
    root=${root%/}
  done
  case $root in
    / | //)
      echo "mrtk_retention_prune: ROOT must not be /" >&2
      return 2
      ;;
  esac
  if [ -L "$root" ]; then
    echo "mrtk_retention_prune: ROOT must not be a symlink: $root" >&2
    return 2
  fi

  local json_root
  json_root=$(_mrtk_retention_json_escape "$root")
  if [ ! -e "$root" ]; then
    printf '{"path":"%s","kept":0,"removed":0,"freedBytes":0,"dryRun":%s,"missing":true}\n' "$json_root" "$dry_run"
    return 0
  fi
  if [ ! -d "$root" ]; then
    echo "mrtk_retention_prune: ROOT is not a directory: $root" >&2
    return 2
  fi

  # Validate the regex once (grep exits 2 on a malformed expression).
  local rc=0
  printf '' | grep -Ex -- "$regex" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "mrtk_retention_prune: invalid NAME_REGEX: $regex" >&2
    return 2
  fi

  local now cutoff
  now=$(date +%s)
  cutoff=$((now - min_age * 86400))

  # Direct non-symlink children as "mtime<TAB>name", newest first, ties by name.
  local -a names=() mtimes=()
  local mt name
  while IFS=$'\t' read -r -d '' mt name; do
    case $name in
      *$'\n'*)
        echo "mrtk_retention_prune: skipping name containing a newline in $root" >&2
        continue
        ;;
    esac
    if printf '%s\n' "$name" | grep -Ex -- "$regex" >/dev/null 2>&1; then
      names+=("$name")
      mtimes+=("$mt")
    fi
  done < <(
    LC_ALL=C find "$root" -mindepth 1 -maxdepth 1 ! -type l -printf '%T@\t%f\0' |
      LC_ALL=C sort -z -t $'\t' -k1,1nr -k2,2
  )

  local i total=${#names[@]} kept=0 removed=0 freed=0
  local target size is_protected p mt_int
  for ((i = 0; i < total; i++)); do
    name=${names[i]}
    if [ "$i" -lt "$keep" ]; then
      kept=$((kept + 1))
      continue
    fi
    mt_int=${mtimes[i]%%.*}
    is_protected=false
    for p in ${protect[@]+"${protect[@]}"}; do
      if [ "$p" = "$name" ]; then
        is_protected=true
        break
      fi
    done
    if [ "$is_protected" = true ] || [ "${mt_int:-0}" -ge "$cutoff" ]; then
      kept=$((kept + 1))
      continue
    fi
    target=$root/$name
    size=$(du -s -B1 -x -- "$target" 2>/dev/null | cut -f1)
    size=${size:-0}
    if [ "$dry_run" = false ]; then
      if [ -d "$target" ]; then
        rm -rf --one-file-system -- "$target" || {
          echo "mrtk_retention_prune: could not remove $target" >&2
          kept=$((kept + 1))
          continue
        }
      else
        rm -f -- "$target" || {
          echo "mrtk_retention_prune: could not remove $target" >&2
          kept=$((kept + 1))
          continue
        }
      fi
    fi
    removed=$((removed + 1))
    freed=$((freed + size))
  done

  printf '{"path":"%s","kept":%d,"removed":%d,"freedBytes":%d,"dryRun":%s}\n' \
    "$json_root" "$kept" "$removed" "$freed" "$dry_run"
  return 0
}
