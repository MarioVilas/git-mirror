#!/usr/bin/env bash
#
# export.sh -- write a manifest of the mirrors in a library, as TSV.
#
# The manifest records enough to recreate each repository *as it is*: not just
# its origin, but the shape it was cloned with. A deliberately shallow or
# single-branch mirror must come back shallow or single-branch, or restoring a
# library would silently change what it contains.
#
# Read-only: this script never modifies a repository.
#
# TSV rather than CSV because it needs no escaping -- `IFS=$'\t' read` is a
# complete and correct parser, whereas naive CSV parsing silently corrupts any
# field containing a comma. The trade is that a field simply cannot contain a
# tab or newline, so such a field is refused rather than written corrupt.
#
set -uo pipefail

# Repository discovery and shape classification, shared with pull.sh.
COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
if [ ! -r "$COMMON" ]; then
  echo "export.sh: cannot read common.sh -- expected it beside this script at $COMMON" >&2
  exit 2
fi
# shellcheck source=common.sh
source "$COMMON"

ROOT=

usage() {
  cat <<'EOF'
Usage: export.sh [-h] [ROOT] > mirrors.tsv

Writes a tab-separated manifest of every git repository below ROOT (default:
the directory containing this script) to standard output.

Columns:

  path     directory, relative to ROOT
  url      remote.origin.url
  shape    full | shallow | single-branch | partial | bare (may combine)
  branch   the tracked branch, for single-branch clones
  depth    approximate history depth, for shallow clones
  filter   partial clone filter, e.g. blob:none

Rows are sorted by path and carry no timestamp, so re-exporting an unchanged
library produces an identical file and diffs stay meaningful.

Repositories that cannot be represented -- no origin configured, or a path
containing a tab or newline -- are reported on stderr and left out, and the
exit status is non-zero so a partial manifest is never mistaken for a complete
one.

  -h   show this help
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      -*) echo "export.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
      *)
        if [ -n "$ROOT" ]; then
          echo "export.sh: only one ROOT may be given (got '$ROOT' and '$1')" >&2
          echo "export.sh: to cover several directories, pass their common parent" >&2
          exit 2
        fi
        ROOT=$1; shift ;;
    esac
  done

  [ -n "$ROOT" ] || ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

  if [ ! -d "$ROOT" ]; then
    echo "export.sh: not a directory: $ROOT" >&2
    exit 2
  fi
  ROOT=$(cd "$ROOT" && pwd) || exit 2
}

# The branch a single-branch clone tracks, derived from its fetch refspec.
# Empty for a wildcard refspec, which tracks everything.
tracked_branch() {
  local repo=$1 spec src
  spec=$(git -C "$repo" config --get remote.origin.fetch 2>/dev/null) || return 0
  [ -n "$spec" ] || return 0
  spec=${spec#+}
  src=${spec%%:*}
  case $src in
    refs/heads/\*) ;;
    refs/heads/*)  echo "${src#refs/heads/}" ;;
  esac
}

# Shallow clones do not record the --depth they were made with, so report the
# history actually present. For the usual --depth 1 this is exactly 1.
approximate_depth() {
  git -C "$1" rev-list --count HEAD 2>/dev/null
}

# TSV cannot escape these, so a field containing one is unrepresentable.
has_forbidden_char() {
  case $1 in
    *$'\t'*|*$'\n'*) return 0 ;;
  esac
  return 1
}

main() {
  parse_args "$@"

  printf '# %s\t%s\t%s\t%s\t%s\t%s\n' path url shape branch depth filter

  # Scanning a large library takes seconds, and longer with a cold cache. Say
  # so, or the wait between the header and the first row looks like a hang.
  # Only when stderr is a terminal, so piped or redirected output stays clean.
  [ -t 2 ] && printf 'export.sh: scanning %s ...\n' "$ROOT" >&2

  local repos=() discovered=() r
  mapfile -t discovered < <(discover_repos "$ROOT")
  for r in "${discovered[@]}"; do
    [ -n "$r" ] && repos+=("$r")
  done

  # Rows are sorted, which means the whole tree must be walked before the first
  # one can be written. Say what was found so the remaining wait is legible.
  [ -t 2 ] && printf 'export.sh: found %d repositories; writing manifest\n' "${#repos[@]}" >&2

  # Rows are emitted as they are produced rather than collected and sorted at
  # the end: discovery already yields paths in LC_ALL=C order, so streaming is
  # both sorted and visibly alive on a big library.
  local status=0
  local repo rel url shape branch depth filter
  for repo in "${repos[@]}"; do
    rel=${repo#"$ROOT"/}

    url=$(git -C "$repo" config --get remote.origin.url 2>/dev/null)
    if [ -z "$url" ]; then
      echo "export.sh: $rel has no origin configured; omitted from the manifest" >&2
      status=1
      continue
    fi

    shape=$(repo_shape "$repo")

    branch=
    depth=
    filter=
    case " $shape " in
      *" single-branch "*) branch=$(tracked_branch "$repo") ;;
    esac
    case " $shape " in
      *" shallow "*) depth=$(approximate_depth "$repo") ;;
    esac
    filter=$(git -C "$repo" config --get remote.origin.partialclonefilter 2>/dev/null)

    if has_forbidden_char "$rel" || has_forbidden_char "$url"; then
      echo "export.sh: $(printf '%q' "$rel") contains a tab or newline and cannot be written as TSV; omitted" >&2
      status=1
      continue
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$url" "$shape" "$branch" "$depth" "$filter"
  done

  return $status
}

main "$@"
