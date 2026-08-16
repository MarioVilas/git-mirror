#!/usr/bin/env bash
#
# pull.sh -- update a library of third-party reference repositories.
#
# Walks every git repository below ROOT and brings it in line with its origin:
# all branches, all tags, full history.
#
# These repositories are read-only mirrors kept for research, not a workspace.
# Local commits and uncommitted changes are therefore discarded rather than
# preserved -- but they are reported, because their presence means something
# wrote to the library that should not have. Untracked files are left alone
# unless one stands in the way of an update.
#
# ROOT itself is never treated as a mirror, so the script is safe to keep in a
# git repository of its own.
#
# Clone shape (shallow, single-branch, partial, bare) is detected and
# preserved. Submodules are not handled: a repository containing them will be
# mirrored, but its submodule contents will not be.
#
set -uo pipefail

# Repository discovery and shape classification, shared with the other tools
# here. Sourced rather than duplicated: it is the subtlest code in the project,
# so this script is not standalone -- common.sh must sit beside it.
COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
if [ ! -r "$COMMON" ]; then
  echo "pull.sh: cannot read common.sh -- expected it beside this script at $COMMON" >&2
  exit 2
fi
# shellcheck source=common.sh
source "$COMMON"

JOBS=4
DRY_RUN=0
QUIET=0
ROOT=
# Global, not local to main: the EXIT trap body is evaluated after main has
# returned, so a local would be out of scope by the time it runs.
OUTDIR=

usage() {
  cat <<'EOF'
Usage: pull.sh [-j N] [-n] [-q] [-h] [ROOT]

Updates every git repository below ROOT (default: the directory containing
this script) to match its origin -- all branches, all tags, full history.

Repositories are treated as read-only mirrors: local commits, uncommitted
changes and local-only branches are discarded and reported as anomalies.
Untracked files are preserved unless one blocks an update.

The SHAPE of each clone is detected and preserved, never "corrected": a
shallow, single-branch, partial or bare mirror is a deliberate choice and is
kept that way. Shape is reported on every line so an unexpected one is
visible. The rule is: respect how a repository was created, disregard what
has since been written into it.

ROOT itself is never updated, even if it is a git repository -- it may be the
workspace holding this script. Repositories busy with another git process, and
clones that have not finished, are skipped rather than half-updated.
Directories alongside repositories that are not repositories are reported too,
so nothing drops out of the sweep unnoticed.

  -j N   repositories to update in parallel (default: 4)
  -n     dry run: list the repositories, change nothing
  -q     quiet: report only anomalies, failures and the summary
  -h     show this help
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      -j) JOBS=${2:-}; shift 2 || true ;;
      -j*) JOBS=${1#-j}; shift ;;
      -n) DRY_RUN=1; shift ;;
      -q) QUIET=1; shift ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      -*) echo "pull.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
      *)
        if [ -n "$ROOT" ]; then
          echo "pull.sh: only one ROOT may be given (got '$ROOT' and '$1')" >&2
          echo "pull.sh: to cover several directories, pass their common parent" >&2
          exit 2
        fi
        ROOT=$1; shift ;;
    esac
  done

  case $JOBS in
    ''|*[!0-9]*|0) echo "pull.sh: -j needs a positive integer" >&2; exit 2 ;;
  esac

  [ -n "$ROOT" ] || ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

  if [ ! -d "$ROOT" ]; then
    echo "pull.sh: not a directory: $ROOT" >&2
    exit 2
  fi

  # Canonicalise: find normalises the paths it prints, so a ROOT carrying a
  # trailing slash (or a relative one) would no longer match them -- and the
  # root repository would stop being excluded from the sweep.
  ROOT=$(cd "$ROOT" && pwd) || exit 2
}

# Reasons to leave a repository untouched this run. Checked before any fetch,
# because a half-applied update is worse than none: an index.lock does not stop
# a fetch, so without this guard a busy repo gets its refs moved and then fails
# on the reset. All checks are read-only and take no locks.
repo_skip_reason() {
  local repo=$1 gitdir

  # Ask git where its metadata lives: a bare repo has no .git subdirectory, and
  # --separate-git-dir puts it somewhere else entirely.
  gitdir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null) || gitdir="$repo/.git"

  if compgen -G "$gitdir/*.lock" >/dev/null 2>&1; then
    echo "another git process is running here"
    return 0
  fi
  if compgen -G "$gitdir/objects/pack/tmp_pack_*" >/dev/null 2>&1; then
    echo "a fetch or clone is in progress"
    return 0
  fi
  if ! git -C "$repo" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    echo "incomplete: HEAD does not resolve to a commit"
    return 0
  fi
  return 1
}

# Directories sitting alongside repositories that are not themselves
# repositories -- an unpacked tarball, or a repository whose .git has gone
# missing. Reported so that a repository cannot silently drop out of the sweep.
# Directories *inside* a repository are ignored; they are its contents.
discover_skipped() {
  local repos=("$@")
  [ ${#repos[@]} -gt 0 ] || return 0

  local -A is_repo=() parents=()
  local r
  for r in "${repos[@]}"; do
    is_repo["$r"]=1
    parents["$(dirname "$r")"]=1
  done

  local parent child inside
  for parent in "${!parents[@]}"; do
    for child in "$parent"/*/; do
      child=${child%/}
      [ -d "$child" ] || continue
      [ -n "${is_repo["$child"]:-}" ] && continue
      inside=0
      for r in "${repos[@]}"; do
        case "$child" in "$r"/*) inside=1; break ;; esac
      done
      [ "$inside" -eq 1 ] && continue
      echo "$child"
    done
  done | sort
}

# The refspecs that mirror local branches, derived from what this clone is
# configured to track rather than hardcoded. A full clone yields the wildcard;
# a single-branch clone yields just its one branch, so no branch outside the
# clone's chosen scope is ever conjured into existence.
mirror_refspecs() {
  local repo=$1 spec src dst
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    spec=${spec#+}
    src=${spec%%:*}
    dst=${spec#*:}
    case $dst in
      refs/remotes/origin/*) ;;
      *) continue ;;
    esac
    echo "+$src:refs/heads/${dst#refs/remotes/origin/}"
  done < <(git -C "$repo" config --get-all remote.origin.fetch 2>/dev/null)
}

# Local branches with no counterpart on origin. Must be collected before the
# pruning fetch, which erases the evidence for branches deleted upstream.
local_only_branches() {
  local repo=$1 branch
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$branch" >/dev/null ||
      echo "$branch"
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)
}

# Report anything a read-only mirror should not contain.
report_anomalies() {
  local repo=$1 rel=$2 orphans=$3

  local branch
  for branch in $orphans; do
    echo "!  $rel  deleted local-only branch '$branch'"
  done

  # Commits reachable from HEAD but from no ref on origin -- authored here.
  local ahead
  ahead=$(git -C "$repo" rev-list --count HEAD --not --remotes=origin 2>/dev/null) || ahead=0
  if [ "$ahead" -gt 0 ]; then
    echo "!  $rel  discarded $ahead local commit(s)"
  fi

  if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "!  $rel  discarded uncommitted changes"
  fi
}

update_repo() {
  local repo=$1 rel=$2 log=$3

  local orphans
  orphans=$(local_only_branches "$repo")

  # Every branch into refs/remotes/origin/*, every tag, and drop what upstream
  # has deleted. Uses the clone's configured refspec, so a narrow clone stays
  # narrow.
  git -C "$repo" fetch --quiet --prune --prune-tags --tags origin >>"$log" 2>&1 || return 1

  # Force local branches onto their upstream counterparts, within the scope
  # this clone tracks. Git refuses to update the checked-out branch, so exclude
  # it here -- the reset below covers it.
  local current specs=() args=()
  current=$(git -C "$repo" symbolic-ref --short -q HEAD)
  mapfile -t specs < <(mirror_refspecs "$repo")
  if [ ${#specs[@]} -gt 0 ] &&
     ! { [ ${#specs[@]} -eq 1 ] && [ "${specs[0]}" = "+refs/heads/$current:refs/heads/$current" ]; }; then
    args=("${specs[@]}")
    [ -n "$current" ] && args+=("^refs/heads/$current")
    git -C "$repo" fetch --quiet --prune origin "${args[@]}" >>"$log" 2>&1 || return 1
  fi

  # Which branch should this mirror sit on? The current one if it still exists
  # upstream, otherwise origin's default branch. This recovers a detached HEAD,
  # a branch deleted upstream, and a renamed default branch.
  local target=$current
  if [ -z "$target" ] || ! git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$target" >/dev/null; then
    git -C "$repo" remote set-head origin --auto >>"$log" 2>&1
    target=$(git -C "$repo" symbolic-ref --short -q refs/remotes/origin/HEAD)
    target=${target#origin/}
    if [ -z "$target" ]; then
      echo "cannot determine origin's default branch" >>"$log"
      return 1
    fi
  fi

  report_anomalies "$repo" "$rel" "$orphans"

  if [ "$target" != "$current" ]; then
    git -C "$repo" checkout --quiet --force -B "$target" "origin/$target" >>"$log" 2>&1 || return 1
    if [ -n "$current" ]; then
      git -C "$repo" branch -D "$current" >>"$log" 2>&1
    fi
  fi

  # Remove branches with no upstream counterpart. A full clone's pruning fetch
  # has already done this; a narrower clone's has not, and leaving them would
  # re-report the same anomaly on every run.
  local stray
  while IFS= read -r stray; do
    [ -n "$stray" ] || continue
    [ "$stray" = "$target" ] && continue
    git -C "$repo" branch -D "$stray" >>"$log" 2>&1
  done < <(local_only_branches "$repo")

  # Discards local commits and uncommitted changes, and overwrites an untracked
  # file only where upstream has one at the same path.
  if ! git -C "$repo" reset --quiet --hard "origin/$target" >>"$log" 2>&1; then
    # An untracked directory can still block the checkout; clear it and retry.
    git -C "$repo" clean -qfd >>"$log" 2>&1
    git -C "$repo" reset --quiet --hard "origin/$target" >>"$log" 2>&1 || return 1
  fi
}

# A bare repository has no working tree, so fetching is the entire job: no
# reset, no HEAD repair, and none of the working-tree anomaly checks, which
# would otherwise mistake a mirror's refs/heads/* -- its whole point -- for
# rogue local branches and delete them.
update_bare_repo() {
  local repo=$1 rel=$2 log=$3

  if [ -n "$(git -C "$repo" config --get-all remote.origin.fetch 2>/dev/null)" ]; then
    # --mirror records +refs/*:refs/*, which already declares its own scope.
    git -C "$repo" fetch --quiet --prune --tags origin >>"$log" 2>&1 || return 1
  else
    # Plain --bare records no refspec at all, so an unqualified fetch would
    # write FETCH_HEAD and leave every branch behind. Supply the refspec.
    git -C "$repo" fetch --quiet --prune --prune-tags --tags origin \
      '+refs/heads/*:refs/heads/*' >>"$log" 2>&1 || return 1
  fi
}

update_any() {
  local repo=$1 rel=$2 log=$3 shape=$4
  if [ "$shape" = bare ]; then
    update_bare_repo "$repo" "$rel" "$log"
  else
    update_repo "$repo" "$rel" "$log"
  fi
}

# Update one repository, writing its report to <out>.out, any git output to
# <out>.err and its outcome to <out>.status. Output is buffered per repository
# so that parallel runs cannot interleave lines.
process_repo() {
  local repo=$1 rel=$2 out=$3

  # Never let an empty or bogus path through: `git -C ""` operates on the
  # current directory, which is emphatically not a mirror.
  if [ -z "$repo" ] || [ ! -d "$repo" ]; then
    echo "failed   ${rel:-<empty path>}  (not a directory)" >"$out.out"
    echo failed >"$out.status"
    return
  fi

  local reason
  if reason=$(repo_skip_reason "$repo"); then
    echo "skipped  $rel  ($reason)" >"$out.out"
    echo skipped >"$out.status"
    return
  fi

  local shape
  shape=$(repo_shape "$repo")

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would    $rel  [$shape]" >"$out.out"
    echo dry >"$out.status"
    return
  fi

  local before after
  before=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)

  if update_any "$repo" "$rel" "$out.err" "$shape" >"$out.out"; then
    after=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)
    if [ "$before" = "$after" ]; then
      [ "$QUIET" -eq 1 ] || echo "ok       $rel  [$shape]" >>"$out.out"
      echo current >"$out.status"
    else
      echo "updated  $rel  [$shape]  $before..$after" >>"$out.out"
      echo updated >"$out.status"
    fi
  else
    echo "failed   $rel  [$shape]" >>"$out.out"
    echo failed >"$out.status"
  fi
}

main() {
  parse_args "$@"

  local repos=() discovered=() r
  mapfile -t discovered < <(discover_repos "$ROOT")
  for r in "${discovered[@]}"; do
    [ -n "$r" ] && repos+=("$r")
  done
  local total=${#repos[@]}

  if [ "$total" -eq 0 ]; then
    echo "no git repositories found under $ROOT" >&2
    return 1
  fi

  local nonrepos=()
  mapfile -t nonrepos < <(discover_skipped "${repos[@]}")

  # Output is held back until every job finishes, so that parallel runs cannot
  # interleave. On a large library that is a long silence; say what is starting.
  # Terminal only, so redirected output stays clean.
  [ -t 2 ] && printf 'pull.sh: updating %d repositories, %d at a time\n' "$total" "$JOBS" >&2

  OUTDIR=$(mktemp -d) || return 1
  trap 'rm -rf "${OUTDIR:-}"' EXIT

  local i rel
  for i in "${!repos[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
    rel=${repos[$i]#"$ROOT"/}
    : >"$OUTDIR/$i.out"; : >"$OUTDIR/$i.err"; : >"$OUTDIR/$i.status"
    process_repo "${repos[$i]}" "$rel" "$OUTDIR/$i" &
  done
  wait

  # Emit in discovery order so the report is stable regardless of -j.
  local updated=0 current=0 failed=0 dry=0 skipped=0
  for i in "${!repos[@]}"; do
    cat "$OUTDIR/$i.out"
    if [ -s "$OUTDIR/$i.err" ] && [ "$(cat "$OUTDIR/$i.status")" = failed ]; then
      sed "s/^/           /" "$OUTDIR/$i.err" >&2
    fi
    case $(cat "$OUTDIR/$i.status") in
      updated) updated=$((updated + 1)) ;;
      current) current=$((current + 1)) ;;
      failed)  failed=$((failed + 1)) ;;
      skipped) skipped=$((skipped + 1)) ;;
      dry)     dry=$((dry + 1)) ;;
    esac
  done

  # Always reported, even under -q: a directory that stopped being a repository
  # is exactly the kind of thing worth noticing.
  local s
  for s in "${nonrepos[@]}"; do
    echo "skipped  ${s#"$ROOT"/}  (not a git repository)"
  done

  local tail="" noun="directories"
  [ ${#nonrepos[@]} -eq 1 ] && noun="directory"
  [ ${#nonrepos[@]} -gt 0 ] && tail="; ${#nonrepos[@]} other $noun skipped"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "$total repos: dry run, nothing changed$tail"
    return 0
  fi

  echo "$total repos: $updated updated, $current up to date, $skipped skipped, $failed failed$tail"
  [ "$failed" -eq 0 ]
}

main "$@"
