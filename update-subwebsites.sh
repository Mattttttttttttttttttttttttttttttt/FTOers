#!/usr/bin/env bash
# symlink-setup.sh
# Reads submodules.json and updates public/.
# Safe to re-run — removes stale symlinks before recreating them.
# Requires: git, jq
#
# Usage: SEE BELOW

set -euo pipefail

USAGE="Usage: update-subwebsites.sh (id...) (--lock id...)
  [no args]         update/build everything, respecting \"updating\" in submodules.json
  [id...]           only touch these repos (by \"path\" root, case-insensitive);
                    forces git update, build still gated by \"updating\"
  --lock [id...]    ditto, but never git-updates these repos (builds still run)
  --help            show this message

JSON Usage:
  Keys denote end paths in public/.
  \"path\":     reserved key. symlinks that directory into this path in public/, or
                run that build script into this path in public/.
  \"updating\": reserved key. By default, skip running this build script or
                skip updating this repo. This is an override, but arguments take precedence."

for arg in "$@"; do
  if [[ "$arg" == "--help" ]]; then
    echo "$USAGE"
    exit 0
  fi
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
CONFIG="$REPO_ROOT/submodules.json"
SUBMODULES_DIR="$REPO_ROOT/submodules"
PUBLIC_DIR="$REPO_ROOT/public"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required. Install with: sudo apt install jq" >&2
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "Error: submodules.json not found at $CONFIG" >&2
  exit 1
fi

# Single parse of submodules.json.
# Reserved keys: "path" (required), "updating" (optional, default true).
# root = first path segment of "path" — the submodule id used for --param matching.
mapfile -t entries < <(jq -r '
  def flatten(prefix):
    if (type == "object") and has("path") then
      [{p: prefix, s: .path, u: (if has("updating") then .updating else true end), r: (.path | split(" ")[0] | sub("^\\./";"") | sub("/$";"") | split("/")[0])}]
    else
      [ to_entries[] | (if prefix == "" then .key else prefix + "/" + .key end) as $np | (.value | flatten($np))[] ]
    end;
  flatten("") | .[] | [.p, .s, (.u | tostring), .r] | @tsv
' "$CONFIG")

# Distinct submodule roots available for CLI selection (case-insensitive).
declare -A valid_roots=()
for entry in "${entries[@]}"; do
  IFS=$'\t' read -r _ _ _ root <<< "$entry"
  valid_roots["${root,,}"]="$root"
done

# Plain params select/force-update those repos.
# Params after --lock skip ONLY the update for those repos (builds can still run).
selected_params=()
lock_params=()
past_lock=false
for arg in "$@"; do
  if [[ "$arg" == "--lock" ]]; then
    past_lock=true
    continue
  fi
  if $past_lock; then
    lock_params+=("$arg")
  else
    selected_params+=("$arg")
  fi
done

# Validate ALL params (both groups) before doing anything else.
declare -A selected_roots=()
declare -A lock_roots=()
bad_params=()

for param in "${selected_params[@]}"; do
  key="${param,,}"
  if [[ -n "${valid_roots[$key]:-}" ]]; then
    selected_roots["${valid_roots[$key]}"]=1
  else
    bad_params+=("$param")
  fi
done

for param in "${lock_params[@]}"; do
  key="${param,,}"
  if [[ -n "${valid_roots[$key]:-}" ]]; then
    lock_roots["${valid_roots[$key]}"]=1
  else
    bad_params+=("$param")
  fi
done

if [[ ${#bad_params[@]} -gt 0 ]]; then
  echo "Error: unrecognized submodule id(s): ${bad_params[*]}" >&2
  echo "Valid ids:" >&2
  printf '  %s\n' "${valid_roots[@]}" | sort -u >&2
  exit 1
fi

echo "Merging submodules in..."
echo ""

# The JSON only prevents a repo from updating if some reference to it has updating: false.
# The updating flag on build scripts has no impact on this.
declare -A root_repo_false=()
declare -A root_repo_true=()
declare -A all_roots=()
for entry in "${entries[@]}"; do
  IFS=$'\t' read -r _ full_path updating_flag root <<< "$entry"
  all_roots["$root"]=1

  src_part="${full_path%% *}"
  src_rel="${src_part#./}"
  is_file=false
  if [[ -f "$SUBMODULES_DIR/$src_rel" ]]; then
    is_file=true
  elif [[ ! -d "$SUBMODULES_DIR/$src_rel" ]] && [[ "$src_part" == *.* ]] && [[ "$src_part" != */ ]]; then
    is_file=true
  fi

  if [[ "$is_file" == "false" ]]; then
    if [[ "$updating_flag" == "false" ]]; then
      root_repo_false["$root"]=1
    else
      root_repo_true["$root"]=1
    fi
  fi
done

declare -A root_default_update=()
for root in "${!all_roots[@]}"; do
  if [[ -n "${root_repo_false[$root]:-}" ]]; then
    root_default_update["$root"]=0
    if [[ -n "${root_repo_true[$root]:-}" ]]; then
      echo "  [warn] $root — inconsistent \"updating\" across repo entries; treating repo as updating: false"
    fi
  else
    root_default_update["$root"]=1
  fi
done

# Final decision per root:
#   - plain params  → only selected roots update (forced, overrides "updating")
#   - no params → follow root_default_update.
#   - --lock roots never run git submodule update, regardless of the above.
update_paths=()
for root in "${!all_roots[@]}"; do
  if [[ ${#selected_roots[@]} -gt 0 ]]; then
    [[ -z "${selected_roots[$root]:-}" ]] && continue
    do_update=1
  else
    do_update="${root_default_update[$root]}"
  fi
  [[ -n "${lock_roots[$root]:-}" ]] && do_update=0
  [[ "$do_update" == "1" ]] && update_paths+=("submodules/$root")
done

if [[ ${#update_paths[@]} -gt 0 ]]; then
  git submodule update --remote --merge --recursive -- "${update_paths[@]}"
else
  echo "  [skip] no submodules flagged for update"
fi

echo "Updating public/ from submodules.json..."
echo ""

printf '%s\n' "${entries[@]}" \
| while IFS=$'\t' read -r pub_path full_path updating_flag root; do

  # plain params
  if [[ ${#selected_roots[@]} -gt 0 && -z "${selected_roots[$root]:-}" ]]; then
    continue
  fi

  link_location="$PUBLIC_DIR/$pub_path"
  link_parent="$(dirname "$link_location")"

  src_part="${full_path%% *}"
  build_args=""
  if [[ "$full_path" == *" "* ]]; then
    build_args="${full_path#* }"
  fi
  src_rel="${src_part#./}"

  is_file=false
  if [[ -f "$SUBMODULES_DIR/$src_rel" ]]; then
    is_file=true
  elif [[ ! -d "$SUBMODULES_DIR/$src_rel" ]] && [[ "$src_part" == *.* ]] && [[ "$src_part" != */ ]]; then
    is_file=true
  fi

  if [[ "$is_file" == "true" ]]; then
    # "updating: false" skips running THIS build script only. repo update not blocked.
    if [[ "$updating_flag" == "false" ]]; then
      echo "  [skip] public/$pub_path — updating: false"
      continue
    fi

    # Build mode: the build script writes its output directly to public/<path>
    # via BUILD_OUT_DIR, so there's no separate copy/move step. The build
    # script's own clean() step removes whatever was there before
    build_script="$SUBMODULES_DIR/$src_rel"
    build_dir="$(dirname "$build_script")"
    build_file="$(basename "$build_script")"

    if [[ ! -f "$build_script" ]]; then
      echo "  [error] public/$pub_path — build script not found at $build_script" >&2
      exit 1
    fi

    mkdir -p "$link_parent"

    echo "  [build] running $build_file for public/$pub_path${build_args:+ with args: $build_args}"
    if [[ -n "$build_args" ]]; then
      ( cd "$build_dir" && BUILD_OUT_DIR="$link_location" node "$build_file" $build_args )
    else
      ( cd "$build_dir" && BUILD_OUT_DIR="$link_location" node "$build_file" )
    fi

    if [[ -z "$(ls -A "$link_location" 2>/dev/null)" ]]; then
      echo "  [clean] public/$pub_path was empty; removing"
      rmdir "$link_location" 2>/dev/null || true
    else
      echo "  [ok] public/$pub_path ← built from $full_path"
    fi

  else
    # Symlink mode: point public/<path> at submodules/<src_path>
    src_rel="${src_rel%/}"
    target_path="$SUBMODULES_DIR/$src_rel"

    # Validate that the submodule source exists
    if [[ ! -e "$target_path" ]]; then
      echo "  [warn] public/$pub_path — target path does not exist: $target_path"
      echo "         All submodules should be in ./submodules"
      continue
    fi

    # Make sure the parent directory of the symlink exists
    mkdir -p "$link_parent"

    # Remove existing symlink (but never a real directory — safety check)
    if [[ -L "$link_location" ]]; then
      echo "  [replace] removing old symlink at public/$pub_path"
      rm "$link_location"
    elif [[ -e "$link_location" ]]; then
      echo "  [error] public/$pub_path exists and is not a symlink — skipping to avoid data loss." >&2
      continue
    fi

    # Compute a relative path from the symlink's parent dir to the target.
    # This keeps the repo portable (no hardcoded absolute paths in symlinks).
    relative_target="$(realpath --relative-to="$link_parent" "$target_path")"

    ln -s "$relative_target" "$link_location"
    echo "  [ok] public/$pub_path → $relative_target"
  fi
done

echo ""
echo "Subwebsites update complete."
read -n 1 -s -r -p "Press any key to exit..."
