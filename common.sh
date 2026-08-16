#!/usr/bin/env bash
#
# common.sh -- repository discovery and classification, shared by the tools in
# this project. Sourced, never executed.
#
# Everything here is read-only: it inspects repositories and reports what it
# finds, and never modifies one.
#

# Is this directory itself a repository root? `git rev-parse` walks upwards, so
# asking it naively from any subdirectory of a repo answers yes. Identity is
# the reliable test: for a bare repo the git dir IS the directory; for a
# worktree the toplevel is. The latter also covers --separate-git-dir, whose
# git dir lives elsewhere entirely.
is_repo_root() {
  local dir=$1 abs
  abs=$(cd "$dir" 2>/dev/null && pwd) || return 1
  if [ "$(git -C "$dir" rev-parse --is-bare-repository 2>/dev/null)" = true ]; then
    [ "$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" = "$abs" ]
  else
    [ "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" = "$abs" ]
  fi
}

# discover_repos ROOT -- repository directories below ROOT, one per line.
#
# Pruning at .git keeps find out of repository internals, which on a repo the
# size of linux dominates the walk. ROOT itself is excluded even when it is a
# repository: it may well be the workspace holding these scripts, and treating
# it as a mirror would reset away real work.
#
# Worktree repos are found by their .git directory. Bare repos have none, so
# they are found by their HEAD file and then verified -- a repository's own
# contents can include a file called HEAD (git's test suite does), and only the
# identity check tells the two apart.
discover_repos() {
  local root=$1
  local worktrees=() prune=() candidates=() r

  mapfile -t worktrees < <(
    find "$root" -type d -name .git -prune -printf '%h\n' 2>/dev/null | LC_ALL=C sort -u
  )

  # Finding bare repos means examining files rather than just directories --
  # ruinous across a worktree the size of firefox. So prune the repositories
  # already found: nearly every file in the tree lives inside one, and none of
  # them can contain a bare repo we care about.
  for r in "${worktrees[@]}"; do
    [ -n "$r" ] || continue
    prune+=(-path "$r" -o)
  done

  if [ ${#prune[@]} -gt 0 ]; then
    unset 'prune[-1]'   # drop the trailing -o
    mapfile -t candidates < <(
      find "$root" \( "${prune[@]}" \) -prune -o -type f -name HEAD -printf '%h\n' 2>/dev/null | LC_ALL=C sort -u
    )
  else
    mapfile -t candidates < <(
      find "$root" -type f -name HEAD -printf '%h\n' 2>/dev/null | LC_ALL=C sort -u
    )
  fi

  {
    # Guarded: printf on an empty array still emits one blank line, which would
    # become a repository whose path is "" -- and `git -C ""` silently means
    # the current directory, so such a phantom would operate on whatever
    # repository the user happens to be standing in.
    [ ${#worktrees[@]} -gt 0 ] && printf '%s\n' "${worktrees[@]}"
    for r in "${candidates[@]}"; do
      [ -n "$r" ] || continue
      is_repo_root "$r" && echo "$r"
    done
  } | grep -vxF -- "$root" | LC_ALL=C sort -u
}

# The shape of a clone: how its owner chose to create it. Reported by pull.sh
# on every run and preserved rather than "corrected" -- a shallow or
# single-branch mirror is a legitimate choice. Content drift (local commits,
# dirty trees, stray branches) is a separate matter.
#
# Attributes are space separated; a plain clone is "full".
repo_shape() {
  local repo=$1 attrs=()

  if [ "$(git -C "$repo" rev-parse --is-bare-repository 2>/dev/null)" = true ]; then
    echo bare
    return
  fi

  [ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)" = true ] && attrs+=(shallow)
  [ -n "$(git -C "$repo" config --get remote.origin.promisor 2>/dev/null)" ] && attrs+=(partial)

  local fetchspec
  fetchspec=$(git -C "$repo" config --get-all remote.origin.fetch 2>/dev/null)
  case "$fetchspec" in
    '')               attrs+=(no-remote) ;;
    *'refs/heads/*'*) ;;
    *)                attrs+=(single-branch) ;;
  esac

  if [ ${#attrs[@]} -eq 0 ]; then
    echo full
  else
    echo "${attrs[*]}"
  fi
}
