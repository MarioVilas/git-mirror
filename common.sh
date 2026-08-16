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
discover_repos() {
  local root=$1 line kind path

  # A single walk that stops at every repository it finds. Descending into a
  # working tree is pure waste -- on a library of this size it meant visiting
  # ~190,000 directories to find nothing, 23x slower than stopping at the repo.
  # It is also wrong: a clone inside another repository's working tree is that
  # repository's content, not a mirror, and a project whose test suite contains
  # .git fixtures (git itself, among others) would otherwise yield dozens of
  # bogus repositories.
  #
  #   branch 1  skip .git directories. A repository's own .git holds HEAD and
  #             objects/, so branch 3 would take it for a bare repo -- and
  #             is_repo_root would agree, since structurally it is one.
  #   branch 2  a directory containing .git is a worktree repository (W)
  #   branch 3  a directory containing HEAD and objects/ may be bare (B),
  #             confirmed below, since a repository's files can look like this
  #
  # -mindepth 1 keeps ROOT itself out of the results: it may be the workspace
  # holding these scripts, and treating it as a mirror would reset real work.
  find "$root" -mindepth 1 \
    \( -type d -name .git -prune \) -o \
    \( -type d -exec test -e '{}/.git' \; -printf 'W %p\n' -prune \) -o \
    \( -type d -exec test -e '{}/HEAD' \; -exec test -d '{}/objects' \; -printf 'B %p\n' -prune \) \
    2>/dev/null |
  while IFS= read -r line; do
    # Fixed-width marker, not field splitting: a path may begin with a space.
    [ -n "$line" ] || continue
    kind=${line:0:1}
    path=${line:2}
    [ -n "$path" ] || continue
    case $kind in
      W) echo "$path" ;;
      B) is_repo_root "$path" && echo "$path" ;;
    esac
  done | LC_ALL=C sort -u
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
