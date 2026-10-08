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
# share a task's directory. The default sits outside the home on purpose:
# Claude Code and other harnesses load instruction files from every parent
# directory, and a copy under the home would hand the worker the supervisor
# contract in the home's own AGENTS.md.
#
# Creation clones origin with --no-local, so even a local-path origin yields an
# independent object store (no worktree, no --shared, no alternates), detaches
# HEAD so the worker cuts its own branch, copies the primary clone's repo-local
# user.name and user.email when set, and writes the registration marker
# <copy>/.git/fm-clone-copy holding `task=<id>` and `project=<physical path>`.
# The marker lives in the git directory, so it never shows as worktree dirt.
# bin/fm-spawn.sh then resets the copy to origin's base branch exactly as it
# refreshes a pooled worktree.
#
# A registered copy is a primary checkout of its own (its git dir is its common
# dir, at <copy>/.git), is the top level of that repository, is not the project
# and shares no git dir with it, and carries a marker that is a regular file
# this user owns, never a symlink, naming that project and, when one is asked
# for, that task. Spawn's isolation assertion, the Claude and agy trust
# registrations, local-only landing, and teardown all decide through
# fm_clone_copy_is_registered, so none of them trusts a caller's word about a
# path.
#
# Callers source this after clearing inherited GIT_DIR-class variables where
# their own safety depends on git's answers (bin/fm-claude-trust.sh does).

FM_CLONE_COPY_MARKER=fm-clone-copy
FM_CLONE_COPY_REASON=

fm_clone_copy_real_dir() { (CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P); }

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
  root=$(fm_clone_copy_root "$1" "$2") || return 1
  printf '%s/%s/%s\n' "$root" "$3" "$(basename "$4")"
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

fm_clone_copy_create() { # <project> <copy> <task-id>
  local project=$1 copy=$2 id=$3 project_real url key value
  project_real=$(fm_clone_copy_real_dir "$project") || {
    echo "error: project '$project' is not an accessible directory" >&2
    return 1
  }
  url=$(fm_clone_copy_origin_url "$project_real") || {
    echo "error: project '$project_real' has no usable origin remote to clone a per-task copy from" >&2
    return 1
  }
  if [ -e "$copy" ] || [ -L "$copy" ]; then
    echo "error: per-task clone path '$copy' already exists; refusing to reuse or replace it" >&2
    return 1
  fi
  mkdir -p "$(dirname "$copy")" || {
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
  printf 'task=%s\nproject=%s\n' "$id" "$project_real" >"$copy/.git/$FM_CLONE_COPY_MARKER" || {
    rm -rf -- "$copy"
    echo "error: could not register the new clone '$copy'" >&2
    return 1
  }
}

fm_clone_copy_is_registered() { # <copy> <project> [<task-id>]
  local copy=$1 project=$2 id=${3:-} copy_real top git_dir common project_real project_common marker
  FM_CLONE_COPY_REASON=
  copy_real=$(fm_clone_copy_real_dir "$copy") || {
    FM_CLONE_COPY_REASON="it is not an accessible directory"
    return 1
  }
  project_real=$(fm_clone_copy_real_dir "$project") || {
    FM_CLONE_COPY_REASON="project '$project' is not an accessible directory"
    return 1
  }
  [ "$copy_real" != "$project_real" ] || {
    FM_CLONE_COPY_REASON="it is the project itself"
    return 1
  }
  top=$(git -C "$copy_real" rev-parse --show-toplevel 2>/dev/null) && top=$(fm_clone_copy_real_dir "$top") || top=
  [ "$top" = "$copy_real" ] || {
    FM_CLONE_COPY_REASON="it is not the top level of a git repository"
    return 1
  }
  git_dir=$(git -C "$copy_real" rev-parse --absolute-git-dir 2>/dev/null) && git_dir=$(fm_clone_copy_real_dir "$git_dir") || git_dir=
  common=$(git -C "$copy_real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && common=$(fm_clone_copy_real_dir "$common") || common=
  [ -n "$git_dir" ] && [ "$git_dir" = "$common" ] && [ "$git_dir" = "$copy_real/.git" ] || {
    FM_CLONE_COPY_REASON="it is a linked worktree or has a relocated git directory, not a clone with its own repository"
    return 1
  }
  project_common=$(git -C "$project_real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    project_common=$(fm_clone_copy_real_dir "$project_common") || project_common=
  [ -n "$project_common" ] && [ "$project_common" != "$common" ] || {
    FM_CLONE_COPY_REASON="it shares the project's git directory"
    return 1
  }
  marker="$copy_real/.git/$FM_CLONE_COPY_MARKER"
  [ ! -L "$marker" ] && [ -f "$marker" ] && [ -O "$marker" ] || {
    FM_CLONE_COPY_REASON="it carries no clone-copy marker owned by this user"
    return 1
  }
  grep -qxF "project=$project_real" "$marker" || {
    FM_CLONE_COPY_REASON="its clone-copy marker names another project"
    return 1
  }
  if [ -n "$id" ] && ! grep -qxF "task=$id" "$marker"; then
    FM_CLONE_COPY_REASON="its clone-copy marker names another task"
    return 1
  fi
}

fm_clone_copy_remove() { # <copy> <project> <task-id>
  local copy=$1 project=$2 id=$3 copy_real
  fm_clone_copy_is_registered "$copy" "$project" "$id" || {
    echo "error: refusing to remove '$copy' as task $id's clone copy: $FM_CLONE_COPY_REASON" >&2
    return 1
  }
  copy_real=$(fm_clone_copy_real_dir "$copy")
  rm -rf -- "$copy_real" || return 1
  rmdir -- "$(dirname "$copy_real")" 2>/dev/null || true
}
