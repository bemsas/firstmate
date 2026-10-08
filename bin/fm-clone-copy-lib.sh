#!/usr/bin/env bash
# Per-task clone copies: the worker copy for a project registered
# `isolation=clone` (bin/fm-project-mode.sh --isolation) is a dedicated full
# `git clone` of the project's origin instead of a Treehouse or Orca worktree.
# This library is the single owner of where such a copy lives, how it is made,
# what proves a directory is one, and how it is removed.
#
# Location: <root>/<task-id>/<project-name>. <root> is the first line of the
# home's config/clone-root (an absolute path) when present, otherwise
# $HOME/.firstmate/clones/<home-token>, where <home-token> is the first twelve
# hex digits of the SHA-256 of the home's physical path so two homes never
# share a task's directory. The root may be neither inside nor an ancestor of
# the home or the project: Claude Code and other harnesses load instruction
# files from every parent directory, and a copy under the home would hand the
# worker the supervisor contract in the home's own AGENTS.md. Task ids and
# project names that are empty, `.`, `..`, or contain `/` or a newline are
# refused, so a copy path never escapes its root.
#
# Creation clones origin with --no-local, so even a local-path origin yields an
# independent object store (no worktree, no --shared, no alternates), detaches
# HEAD so the worker cuts its own branch, copies the primary clone's repo-local
# user.name and user.email when set, and writes the registration marker
# <copy>/.git/fm-clone-copy. The marker lives in the git directory, so it never
# shows as worktree dirt, and holds exactly these lines in this order:
#   schema=fm-clone-copy.v1
#   task=<task-id>
#   home=<physical home>
#   config=<absolute config dir>
#   root=<physical copies root>
#   copy=<physical copy path>
#   project=<physical project>
#   repo=<device>:<inode> of <copy>/.git
# bin/fm-spawn.sh then resets the copy to origin's base branch exactly as it
# refreshes a pooled worktree.
#
# fm_clone_copy_is_registered is the one proof every consumer decides through:
# spawn's isolation assertion and relaunch, the Claude and agy trust
# registrations, local-only landing, the test runner's placement guard, and
# teardown. It never takes the marker's word for where the copy belongs. It
# recomputes the copies root from the caller's home and config, requires the
# copy to be exactly <root>/<task-id>/<project-name> with no symlinked
# component below the root, requires a primary checkout of its own that shares
# no git dir with the project and is no ancestor of the project or the home,
# and then requires a strictly parsed, user-owned, non-symlink marker whose
# every field equals those recomputed values. The repo field binds the marker
# to that exact git directory, so a marker copied into another repository is
# refused, and the copy field refuses a registered clone moved anywhere else.
# fm_clone_copy_remove proves containment under the recomputed root again,
# independently of the marker, immediately before it deletes.
#
# Callers source this after clearing inherited GIT_DIR-class variables where
# their own safety depends on git's answers (bin/fm-claude-trust.sh does).

FM_CLONE_COPY_MARKER=fm-clone-copy
FM_CLONE_COPY_SCHEMA=fm-clone-copy.v1
FM_CLONE_COPY_REASON=

fm_clone_copy_real_dir() { (CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P); }

fm_clone_copy_abs_dir() { # <dir>: physical when it exists, else absolute as given
  local real
  if real=$(fm_clone_copy_real_dir "$1"); then
    printf '%s\n' "$real"
  else
    case "$1" in
      /*) printf '%s\n' "${1%/}" ;;
      *) printf '%s/%s\n' "$(pwd -P)" "${1%/}" ;;
    esac
  fi
}

fm_clone_copy_name_ok() { # <segment>
  case "$1" in
    '' | . | .. | */* | *$'\n'*) return 1 ;;
  esac
}

fm_clone_copy_inside() { # <ancestor> <path>: path is ancestor or below it
  [ "$2" = "$1" ] && return 0
  case "$2" in "$1"/*) return 0 ;; esac
  return 1
}

fm_clone_copy_repo_id() { # <git-dir>
  perl -e '@s = stat($ARGV[0]) or exit 1; print "$s[0]:$s[1]\n"' -- "$1" 2>/dev/null
}

fm_clone_copy_home_token() { # <home>
  local real hash
  real=$(fm_clone_copy_real_dir "$1") || real=$1
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$real" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$real" | sha256sum | awk '{print $1}')
  else
    return 1
  fi
  case "$hash" in '' | *[!0-9a-fA-F]*) return 1 ;; esac
  printf '%s\n' "${hash:0:12}"
}

fm_clone_copy_root() { # <home> <config-dir>
  local home=$1 config=$2 root token
  if [ -f "$config/clone-root" ]; then
    root=$(head -n 1 "$config/clone-root" | tr -d '\r')
    case "$root" in
      /*) printf '%s\n' "${root%/}"; return 0 ;;
    esac
    echo "error: $config/clone-root must hold an absolute path, not '$root'" >&2
    return 1
  fi
  [ -n "${HOME:-}" ] || { echo "error: HOME is not set, so the default clone root cannot be located" >&2; return 1; }
  token=$(fm_clone_copy_home_token "$home") || { echo "error: could not derive a home token for the default clone root" >&2; return 1; }
  printf '%s\n' "$HOME/.firstmate/clones/$token"
}

fm_clone_copy_path() { # <home> <config-dir> <task-id> <project>
  local root
  fm_clone_copy_name_ok "$3" || { echo "error: task id '$3' cannot name a clone directory" >&2; return 1; }
  fm_clone_copy_name_ok "$(basename "$4")" || { echo "error: project '$4' cannot name a clone directory" >&2; return 1; }
  root=$(fm_clone_copy_root "$1" "$2") || return 1
  printf '%s/%s/%s\n' "$root" "$3" "$(basename "$4")"
}

fm_clone_copy_root_overlaps() { # <root-real> <home-real> <project-real>
  fm_clone_copy_inside "$1" "$2" || fm_clone_copy_inside "$2" "$1" ||
    fm_clone_copy_inside "$1" "$3" || fm_clone_copy_inside "$3" "$1"
}

# Sets FM_CLONE_COPY_ROOT_REAL and FM_CLONE_COPY_EXPECTED when <copy> is exactly
# the copy path the home's config names for <task-id> and <project>, with no
# symlinked component below an existing root that sits outside the home and the
# project. Decided from the caller's home and config alone, never the marker.
FM_CLONE_COPY_ROOT_REAL=
FM_CLONE_COPY_EXPECTED=
fm_clone_copy_contained() { # <copy> <project> <task-id> <home> <config-dir>
  local copy=$1 project=$2 id=$3 home=$4 config=$5 root name copy_real home_real project_real
  FM_CLONE_COPY_ROOT_REAL=
  FM_CLONE_COPY_EXPECTED=
  fm_clone_copy_name_ok "$id" || { FM_CLONE_COPY_REASON="task id '$id' cannot name a clone directory"; return 1; }
  project_real=$(fm_clone_copy_real_dir "$project") || { FM_CLONE_COPY_REASON="project '$project' is not an accessible directory"; return 1; }
  name=$(basename "$project_real")
  fm_clone_copy_name_ok "$name" || { FM_CLONE_COPY_REASON="project name '$name' cannot name a clone directory"; return 1; }
  home_real=$(fm_clone_copy_real_dir "$home") || { FM_CLONE_COPY_REASON="home '$home' is not an accessible directory"; return 1; }
  root=$(fm_clone_copy_root "$home_real" "$config" 2>/dev/null) || { FM_CLONE_COPY_REASON="the home's clone root cannot be resolved"; return 1; }
  FM_CLONE_COPY_ROOT_REAL=$(fm_clone_copy_real_dir "$root") || { FM_CLONE_COPY_REASON="clone root '$root' does not exist"; return 1; }
  if fm_clone_copy_root_overlaps "$FM_CLONE_COPY_ROOT_REAL" "$home_real" "$project_real"; then
    FM_CLONE_COPY_REASON="clone root '$FM_CLONE_COPY_ROOT_REAL' overlaps the home or the project"
    return 1
  fi
  FM_CLONE_COPY_EXPECTED="$FM_CLONE_COPY_ROOT_REAL/$id/$name"
  if [ -L "$FM_CLONE_COPY_ROOT_REAL/$id" ] || [ -L "$FM_CLONE_COPY_EXPECTED" ]; then
    FM_CLONE_COPY_REASON="a component of '$FM_CLONE_COPY_EXPECTED' is a symlink"
    return 1
  fi
  copy_real=$(fm_clone_copy_real_dir "$copy") || { FM_CLONE_COPY_REASON="it is not an accessible directory"; return 1; }
  [ "$copy_real" = "$FM_CLONE_COPY_EXPECTED" ] || {
    FM_CLONE_COPY_REASON="it is '$copy_real', not this task's copy path '$FM_CLONE_COPY_EXPECTED'"
    return 1
  }
}

fm_clone_copy_origin_url() { # <project>
  local project=$1 url
  url=$(git -C "$project" remote get-url origin 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  case "$url" in
    /* | *:*) ;;
    *) url=$(cd "$project" && fm_clone_copy_real_dir "$url") || return 1 ;;
  esac
  printf '%s\n' "$url"
}

fm_clone_copy_create() { # <project> <home> <config-dir> <task-id>
  local project=$1 home=$2 config=$3 id=$4 project_real home_real root root_real copy url key value repo
  project_real=$(fm_clone_copy_real_dir "$project") || {
    echo "error: project '$project' is not an accessible directory" >&2
    return 1
  }
  home_real=$(fm_clone_copy_real_dir "$home") || {
    echo "error: home '$home' is not an accessible directory" >&2
    return 1
  }
  url=$(fm_clone_copy_origin_url "$project_real") || {
    echo "error: project '$project_real' has no usable origin remote to clone a per-task copy from" >&2
    return 1
  }
  copy=$(fm_clone_copy_path "$home_real" "$config" "$id" "$project_real") || return 1
  root=${copy%/*/*}
  if ! mkdir -p "$root" || ! root_real=$(fm_clone_copy_real_dir "$root"); then
    echo "error: could not create clone root '$root'" >&2
    return 1
  fi
  if fm_clone_copy_root_overlaps "$root_real" "$home_real" "$project_real"; then
    echo "error: clone root '$root_real' overlaps the home or the project; choose a config/clone-root outside both" >&2
    return 1
  fi
  copy="$root_real/$id/$(basename "$project_real")"
  if [ -e "$copy" ] || [ -L "$copy" ] || [ -L "$root_real/$id" ]; then
    echo "error: per-task clone path '$copy' already exists; refusing to reuse or replace it" >&2
    return 1
  fi
  mkdir -p "$root_real/$id" || {
    echo "error: could not create the clone directory for '$copy'" >&2
    return 1
  }
  if ! git clone --quiet --no-local -- "$url" "$copy" >&2; then
    rm -rf -- "$copy"
    echo "error: could not clone '$url' into '$copy'" >&2
    return 1
  fi
  if ! git -C "$copy" checkout --quiet --detach; then
    rm -rf -- "$copy"
    echo "error: could not detach HEAD in the new clone '$copy'" >&2
    return 1
  fi
  for key in user.name user.email; do
    value=$(git -C "$project_real" config --local --get "$key" 2>/dev/null) || continue
    git -C "$copy" config --local "$key" "$value"
  done
  repo=$(fm_clone_copy_repo_id "$copy/.git") || {
    rm -rf -- "$copy"
    echo "error: could not read the identity of the new clone '$copy'" >&2
    return 1
  }
  printf 'schema=%s\ntask=%s\nhome=%s\nconfig=%s\nroot=%s\ncopy=%s\nproject=%s\nrepo=%s\n' \
    "$FM_CLONE_COPY_SCHEMA" "$id" "$home_real" "$(fm_clone_copy_abs_dir "$config")" \
    "$root_real" "$copy" "$project_real" "$repo" >"$copy/.git/$FM_CLONE_COPY_MARKER" || {
    rm -rf -- "$copy"
    echo "error: could not register the new clone '$copy'" >&2
    return 1
  }
}

# Prints the value of one field of <copy>'s marker after a strict parse of the
# whole file: exactly the schema's eight lines, in order, nothing else.
fm_clone_copy_marker_field() { # <copy> <key>
  local marker="$1/.git/$FM_CLONE_COPY_MARKER"
  [ ! -L "$marker" ] && [ -f "$marker" ] && [ -O "$marker" ] || return 1
  awk -v want="$2" -v schema="$FM_CLONE_COPY_SCHEMA" '
    BEGIN { split("schema task home config root copy project repo", keys, " ") }
    {
      n++
      if (n > 8) { bad = 1; exit }
      eq = index($0, "=")
      if (eq < 2 || substr($0, 1, eq - 1) != keys[n]) { bad = 1; exit }
      value = substr($0, eq + 1)
      if (value == "") { bad = 1; exit }
      if (n == 1 && value != schema) { bad = 1; exit }
      if (keys[n] == want) found = value
    }
    END { if (bad || n != 8 || found == "") exit 1; print found }
  ' "$marker"
}

fm_clone_copy_is_registered() { # <copy> <project> <task-id> <home> <config-dir>
  local copy=$1 project=$2 id=$3 home=$4 config=$5 top git_dir common project_real home_real project_common repo field want got
  FM_CLONE_COPY_REASON=
  fm_clone_copy_contained "$copy" "$project" "$id" "$home" "$config" || return 1
  project_real=$(fm_clone_copy_real_dir "$project")
  home_real=$(fm_clone_copy_real_dir "$home")
  if fm_clone_copy_inside "$FM_CLONE_COPY_EXPECTED" "$project_real" || fm_clone_copy_inside "$FM_CLONE_COPY_EXPECTED" "$home_real"; then
    FM_CLONE_COPY_REASON="it is the project, the home, or an ancestor of either"
    return 1
  fi
  top=$(git -C "$FM_CLONE_COPY_EXPECTED" rev-parse --show-toplevel 2>/dev/null) && top=$(fm_clone_copy_real_dir "$top") || top=
  [ "$top" = "$FM_CLONE_COPY_EXPECTED" ] || {
    FM_CLONE_COPY_REASON="it is not the top level of a git repository"
    return 1
  }
  git_dir=$(git -C "$FM_CLONE_COPY_EXPECTED" rev-parse --absolute-git-dir 2>/dev/null) && git_dir=$(fm_clone_copy_real_dir "$git_dir") || git_dir=
  common=$(git -C "$FM_CLONE_COPY_EXPECTED" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && common=$(fm_clone_copy_real_dir "$common") || common=
  [ -n "$git_dir" ] && [ "$git_dir" = "$common" ] && [ "$git_dir" = "$FM_CLONE_COPY_EXPECTED/.git" ] && [ ! -L "$FM_CLONE_COPY_EXPECTED/.git" ] || {
    FM_CLONE_COPY_REASON="it is a linked worktree or has a relocated git directory, not a clone with its own repository"
    return 1
  }
  project_common=$(git -C "$project_real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    project_common=$(fm_clone_copy_real_dir "$project_common") || project_common=
  [ -n "$project_common" ] && [ "$project_common" != "$common" ] || {
    FM_CLONE_COPY_REASON="it shares the project's git directory"
    return 1
  }
  repo=$(fm_clone_copy_repo_id "$git_dir") || {
    FM_CLONE_COPY_REASON="its git directory's identity cannot be read"
    return 1
  }
  for field in task home config root copy project repo; do
    case "$field" in
      task) want=$id ;;
      home) want=$home_real ;;
      config) want=$(fm_clone_copy_abs_dir "$config") ;;
      root) want=$FM_CLONE_COPY_ROOT_REAL ;;
      copy) want=$FM_CLONE_COPY_EXPECTED ;;
      project) want=$project_real ;;
      repo) want=$repo ;;
    esac
    got=$(fm_clone_copy_marker_field "$FM_CLONE_COPY_EXPECTED" "$field") || {
      FM_CLONE_COPY_REASON="it carries no well-formed clone-copy marker owned by this user"
      return 1
    }
    [ "$got" = "$want" ] || {
      FM_CLONE_COPY_REASON="its clone-copy marker records $field '$got', not '$want'"
      return 1
    }
  done
}

fm_clone_copy_remove() { # <copy> <project> <task-id> <home> <config-dir>
  local copy=$1 project=$2 id=$3 home=$4 config=$5 target
  fm_clone_copy_is_registered "$copy" "$project" "$id" "$home" "$config" || {
    echo "error: refusing to remove '$copy' as task $id's clone copy: $FM_CLONE_COPY_REASON" >&2
    return 1
  }
  # Containment is proved again from the home's config alone, right before the
  # delete, so the marker inside the target is never the sole authority.
  fm_clone_copy_contained "$copy" "$project" "$id" "$home" "$config" || {
    echo "error: refusing to remove '$copy' as task $id's clone copy: $FM_CLONE_COPY_REASON" >&2
    return 1
  }
  target=$FM_CLONE_COPY_EXPECTED
  case "$target" in
    "$FM_CLONE_COPY_ROOT_REAL"/?*/?*) ;;
    *) echo "error: refusing to remove '$target': it is not below clone root '$FM_CLONE_COPY_ROOT_REAL'" >&2; return 1 ;;
  esac
  rm -rf -- "$target" || return 1
  rmdir -- "$FM_CLONE_COPY_ROOT_REAL/$id" 2>/dev/null || true
}
