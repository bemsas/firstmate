#!/usr/bin/env bash
# fm-worktree-isolation-lib.sh - the ONE owner of firstmate's worktree-isolation
# predicate: is a given path an isolated, disposable worktree of a given
# project, rather than that project itself or the repository's primary
# checkout?
#
# This predicate was born inline in bin/fm-spawn.sh, where it guards a launch.
# It lives here because a launch is not the only moment it has to hold. A
# terminal endpoint restored after a machine reboot comes back with a working
# directory the record never chose (docs/herdr-backend.md "Restored endpoints
# do not keep their working directory"), so the same question has to be asked
# again against the endpoint's LIVE path - and asked with the same answer, not
# a second copy of the rule that can drift. bin/fm-spawn.sh's
# spawn_worktree_isolated and bin/fm-endpoint-rebind.sh both call this.
#
# This file is sourced by scripts and has no side effects on source.

# fm_worktree_isolation_check: 0 when <path> is an isolated worktree of
# <project>; 1 otherwise. On every call it sets:
#   FM_WORKTREE_ISOLATION_TOP     the worktree root the check read (may be empty)
#   FM_WORKTREE_ISOLATION_REASON  a short phrase naming why a rejected path
#                                 failed (empty on success)
#
# Isolation means all of: a readable directory, that is its own worktree root,
# that is not <project> itself, and whose git directory is not <project>'s
# common git dir - the last being what separates a linked worktree from the
# repository's primary checkout, which shares that common dir.
#
# Comparisons are PHYSICAL on both sides. A backend's own current-path read
# reports the OS-level, physically resolved directory, so comparing it against
# a still-symlinked project path (macOS's /tmp -> /private/tmp) would misfire
# in both directions: a false negative that never notices the endpoint left the
# project, and a false positive that refuses a path which never tangled
# (docs/herdr-backend.md "Known gaps").
# shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
fm_worktree_isolation_check() {  # <path> <project>
  local path=$1 project=$2 wt_real wt_top_real wt_git_dir proj_real proj_common
  FM_WORKTREE_ISOLATION_TOP=
  FM_WORKTREE_ISOLATION_REASON=
  wt_real=
  if ! wt_real=$(cd "$path" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  if [ -z "$wt_real" ]; then
    FM_WORKTREE_ISOLATION_REASON="it is not a readable directory"
    return 1
  fi
  proj_real=$(cd "$project" 2>/dev/null && pwd -P) || proj_real=$project
  FM_WORKTREE_ISOLATION_TOP=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)
  # A path in no repository leaves the toplevel empty, and that empty value must
  # never reach `cd`: bash before 5.3 accepts `cd ""` as a successful no-op, so
  # it would resolve to the CALLER's own cwd and report the path as a
  # subdirectory of whatever checkout firstmate happens to be running from.
  wt_top_real=
  if [ -n "$FM_WORKTREE_ISOLATION_TOP" ] \
    && ! wt_top_real=$(cd "$FM_WORKTREE_ISOLATION_TOP" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  if [ -z "$wt_top_real" ]; then
    FM_WORKTREE_ISOLATION_REASON="it is not inside a git worktree"
    return 1
  fi
  if [ "$wt_real" != "$wt_top_real" ]; then
    FM_WORKTREE_ISOLATION_REASON="it is a subdirectory of worktree root '$wt_top_real', not a worktree root"
    return 1
  fi
  if [ "$wt_real" = "$proj_real" ]; then
    FM_WORKTREE_ISOLATION_REASON="it is the spawning project itself"
    return 1
  fi
  # The primary checkout uses the repository's common git dir as its own git
  # dir. A linked spawning home has a different top-level, but the same common
  # dir, so comparing only the two working directories cannot protect primary.
  wt_git_dir=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) &&
    wt_git_dir=$(cd "$wt_git_dir" 2>/dev/null && pwd -P) || wt_git_dir=
  proj_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    proj_common=$(cd "$proj_common" 2>/dev/null && pwd -P) || proj_common=
  if [ -z "$wt_git_dir" ] || [ -z "$proj_common" ]; then
    FM_WORKTREE_ISOLATION_REASON="its git directory could not be resolved"
    return 1
  fi
  if [ "$wt_git_dir" = "$proj_common" ]; then
    FM_WORKTREE_ISOLATION_REASON="it is the repository's primary checkout (its git dir is the spawning project's common git dir)"
    return 1
  fi
  return 0
}
