#!/usr/bin/env bash
# Test suite for export.sh
#
# Fixtures, assertions and the runner live in test_common.sh.
# Run:  ./export_test.sh  [FILTER=substring]

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUITE="export"
# shellcheck source=test_common.sh
source "$SCRIPT_DIR/test_common.sh"

EXPORT="$SCRIPT_DIR/export.sh"

run_export() { "$EXPORT" "$@" >"$WORK/stdout" 2>"$WORK/stderr"; echo $? >"$WORK/exit"; }
export_exit() { cat "$WORK/exit"; }
export_stdout() { cat "$WORK/stdout"; }
export_stderr() { cat "$WORK/stderr"; }

# Data rows only, without the comment header.
export_rows() { grep -v '^#' "$WORK/stdout" || true; }

# row ROW COL -- one field, 1-indexed, from the data rows
field() { export_rows | sed -n "${1}p" | cut -f"$2"; }

# The manifest column order, for readable tests.
readonly C_PATH=1 C_URL=2 C_SHAPE=3 C_BRANCH=4 C_DEPTH=5 C_FILTER=6

echo "Running export.sh tests"

# ---------------------------------------------------------------------------
if test_case "exports_path_url_and_shape_for_a_full_clone"; then
  new_upstream alpha
  clone_repo tools alpha

  run_export "$WORK/lib"

  assert_eq "0" "$(export_exit)" "exit code"
  assert_eq "1" "$(export_rows | wc -l)" "one data row"
  assert_eq "tools/alpha" "$(field 1 $C_PATH)" "path is relative to the root"
  assert_eq "$WORK/up/alpha.git" "$(field 1 $C_URL)" "origin url"
  assert_eq "full" "$(field 1 $C_SHAPE)" "shape"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "writes_a_commented_header_naming_the_columns"; then
  new_upstream alpha
  clone_repo tools alpha

  run_export "$WORK/lib"

  header=$(grep '^#' "$WORK/stdout" | head -1)
  assert_contains "$header" "path" "header names path"
  assert_contains "$header" "url" "header names url"
  assert_contains "$header" "shape" "header names shape"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "rows_are_sorted_by_path"; then
  for n in charlie alpha bravo; do new_upstream "$n"; clone_repo tools "$n"; done

  run_export "$WORK/lib"

  assert_eq "tools/alpha
tools/bravo
tools/charlie" "$(export_rows | cut -f$C_PATH)" "sorted paths"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "every_row_has_the_same_number_of_columns"; then
  new_upstream alpha; new_upstream beta
  clone_repo tools alpha
  clone_repo_shallow docs beta

  run_export "$WORK/lib"

  counts=$(export_rows | awk -F'\t' '{print NF}' | sort -u | tr '\n' ' ')
  assert_eq "6 " "$counts" "constant column count across rows"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "records_depth_for_a_shallow_clone"; then
  new_upstream alpha
  upstream_commit alpha
  upstream_commit alpha
  clone_repo_shallow tools alpha

  run_export "$WORK/lib"

  assert_contains "$(field 1 $C_SHAPE)" "shallow" "shape includes shallow"
  assert_eq "1" "$(field 1 $C_DEPTH)" "depth recorded"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "records_the_branch_of_a_single_branch_clone"; then
  new_upstream alpha
  upstream_commit alpha feature-x
  clone_repo_single_branch tools alpha

  run_export "$WORK/lib"

  assert_contains "$(field 1 $C_SHAPE)" "single-branch" "shape includes single-branch"
  assert_eq "main" "$(field 1 $C_BRANCH)" "tracked branch recorded"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "records_the_filter_of_a_partial_clone"; then
  new_upstream alpha
  clone_repo_partial tools alpha

  run_export "$WORK/lib"

  assert_contains "$(field 1 $C_SHAPE)" "partial" "shape includes partial"
  assert_eq "blob:none" "$(field 1 $C_FILTER)" "filter recorded"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "exports_a_bare_repository"; then
  new_upstream alpha
  clone_repo_mirror tools alpha

  run_export "$WORK/lib"

  assert_eq "0" "$(export_exit)" "exit code"
  assert_eq "tools/alpha.git" "$(field 1 $C_PATH)" "bare repo path"
  assert_eq "bare" "$(field 1 $C_SHAPE)" "bare shape"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "excludes_the_root_repository_itself"; then
  new_upstream alpha
  clone_repo tools alpha
  git init -q -b main "$WORK/lib"          # the workspace holding the scripts

  run_export "$WORK/lib"

  assert_eq "1" "$(export_rows | wc -l)" "only the mirror is exported"
  assert_eq "tools/alpha" "$(field 1 $C_PATH)" "the mirror, not the root"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "ignores_directories_that_are_not_repositories"; then
  new_upstream alpha
  clone_repo tools alpha
  mkdir -p "$WORK/lib/tools/unpacked-tarball"
  echo hello >"$WORK/lib/tools/unpacked-tarball/README"

  run_export "$WORK/lib"

  assert_eq "1" "$(export_rows | wc -l)" "only the repository is exported"
  assert_not_contains "$(export_stdout)" "unpacked-tarball" "tarball not in the manifest"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "a_repository_without_an_origin_is_reported_and_excluded"; then
  new_upstream alpha
  clone_repo tools alpha
  mkdir -p "$WORK/lib/tools/orphan"
  git init -q -b main "$WORK/lib/tools/orphan"
  echo x >"$WORK/lib/tools/orphan/x"
  git -C "$WORK/lib/tools/orphan" add -A
  git -C "$WORK/lib/tools/orphan" commit -qm "no remote"

  run_export "$WORK/lib"

  assert_eq "1" "$(export_exit)" "non-zero exit: the manifest is incomplete"
  assert_eq "1" "$(export_rows | wc -l)" "only the usable repository is exported"
  assert_contains "$(export_stderr)" "tools/orphan" "the unusable repository is named"
  end_case
fi

# ---------------------------------------------------------------------------
# TSV has no escaping, so a field that cannot be represented must be refused
# rather than silently written as a corrupt row.
if test_case "refuses_to_write_a_path_containing_a_tab"; then
  new_upstream alpha
  new_upstream beta
  clone_repo tools alpha
  mkdir -p "$WORK/lib/tools"
  git clone -q "$WORK/up/beta.git" "$WORK/lib/tools/we$(printf '\t')ird"

  run_export "$WORK/lib"

  assert_eq "1" "$(export_exit)" "non-zero exit"
  assert_contains "$(export_stderr)" "tab" "error explains the problem"
  assert_eq "1" "$(export_rows | wc -l)" "the representable repository is still exported"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "an_empty_library_exports_a_header_and_no_rows"; then
  mkdir -p "$WORK/lib/empty"

  run_export "$WORK/lib"

  assert_eq "0" "$(export_rows | wc -l)" "no data rows"
  assert_contains "$(export_stdout)" "path" "header still written"
  end_case
fi

# ---------------------------------------------------------------------------
# `export.sh */` expands to many directories; silently exporting only the last
# one produces a manifest that looks complete and is not.
if test_case "rejects_more_than_one_root_argument"; then
  new_upstream alpha
  clone_repo tools alpha
  clone_repo docs alpha 2>/dev/null || true

  run_export "$WORK/lib/tools" "$WORK/lib/docs"

  assert_eq "2" "$(export_exit)" "exit code"
  assert_contains "$(export_stderr)" "one" "error explains only one root is accepted"
  assert_eq "0" "$(export_rows | wc -l)" "no misleading partial manifest"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "writes_nothing_to_stderr_on_a_clean_run"; then
  new_upstream alpha
  clone_repo tools alpha

  run_export "$WORK/lib"

  assert_eq "" "$(export_stderr)" "stderr is clean when not attached to a terminal"
  end_case
fi

finish_tests
