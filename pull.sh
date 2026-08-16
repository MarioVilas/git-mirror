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
set -uo pipefail

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
      *) ROOT=$1; shift ;;
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
}

# Repository working directories below ROOT. Pruning at .git keeps find out of
# repository internals, which on a repo the size of linux dominates the walk.
discover_repos() {
  find "$ROOT" -type d -name .git -prune -printf '%h\n' 2>/dev/null | sort
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
  # has deleted.
  git -C "$repo" fetch --quiet --prune --prune-tags --tags origin >>"$log" 2>&1 || return 1

  # Force local branches onto their upstream counterparts and prune those that
  # no longer exist upstream. Git refuses to update the checked-out branch, so
  # exclude it from this refspec -- the reset below covers it.
  local current refspecs
  current=$(git -C "$repo" symbolic-ref --short -q HEAD)
  refspecs=('+refs/heads/*:refs/heads/*')
  [ -n "$current" ] && refspecs+=("^refs/heads/$current")
  git -C "$repo" fetch --quiet --prune origin "${refspecs[@]}" >>"$log" 2>&1 || return 1

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

  # Discards local commits and uncommitted changes, and overwrites an untracked
  # file only where upstream has one at the same path.
  if ! git -C "$repo" reset --quiet --hard "origin/$target" >>"$log" 2>&1; then
    # An untracked directory can still block the checkout; clear it and retry.
    git -C "$repo" clean -qfd >>"$log" 2>&1
    git -C "$repo" reset --quiet --hard "origin/$target" >>"$log" 2>&1 || return 1
  fi
}

# Update one repository, writing its report to <out>.out, any git output to
# <out>.err and its outcome to <out>.status. Output is buffered per repository
# so that parallel runs cannot interleave lines.
process_repo() {
  local repo=$1 rel=$2 out=$3

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would    $rel" >"$out.out"
    echo dry >"$out.status"
    return
  fi

  local before after
  before=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)

  if update_repo "$repo" "$rel" "$out.err" >"$out.out"; then
    after=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)
    if [ "$before" = "$after" ]; then
      [ "$QUIET" -eq 1 ] || echo "ok       $rel" >>"$out.out"
      echo current >"$out.status"
    else
      echo "updated  $rel  $before..$after" >>"$out.out"
      echo updated >"$out.status"
    fi
  else
    echo "failed   $rel" >>"$out.out"
    echo failed >"$out.status"
  fi
}

main() {
  parse_args "$@"

  local repos=()
  mapfile -t repos < <(discover_repos)
  local total=${#repos[@]}

  if [ "$total" -eq 0 ]; then
    echo "no git repositories found under $ROOT" >&2
    return 1
  fi

  local skipped=()
  mapfile -t skipped < <(discover_skipped "${repos[@]}")

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
  local updated=0 current=0 failed=0 dry=0
  for i in "${!repos[@]}"; do
    cat "$OUTDIR/$i.out"
    if [ -s "$OUTDIR/$i.err" ] && [ "$(cat "$OUTDIR/$i.status")" = failed ]; then
      sed "s/^/           /" "$OUTDIR/$i.err" >&2
    fi
    case $(cat "$OUTDIR/$i.status") in
      updated) updated=$((updated + 1)) ;;
      current) current=$((current + 1)) ;;
      failed)  failed=$((failed + 1)) ;;
      dry)     dry=$((dry + 1)) ;;
    esac
  done

  # Always reported, even under -q: a directory that stopped being a repository
  # is exactly the kind of thing worth noticing.
  local s
  for s in "${skipped[@]}"; do
    echo "skipped  ${s#"$ROOT"/}  (not a git repository)"
  done

  local tail=""
  [ ${#skipped[@]} -gt 0 ] && tail="; ${#skipped[@]} skipped"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "$total repos: dry run, nothing changed$tail"
    return 0
  fi

  echo "$total repos: $updated updated, $current up to date, $failed failed$tail"
  [ "$failed" -eq 0 ]
}

main "$@"
