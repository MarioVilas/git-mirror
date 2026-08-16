#!/usr/bin/env bash
# Test suite for pull.sh
#
# Each test builds a throwaway fixture: bare "upstream" repos plus clones
# arranged as <root>/<category>/<repo>, mirroring the real library layout.
# Run:  bash pull_test.sh  [test_name_substring]

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PULL="$SCRIPT_DIR/pull.sh"
TESTROOT="${TMPDIR:-/tmp}/pull-sh-tests.$$"

# Isolate from the user's git config so tests are deterministic.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

PASS=0
FAIL=0
FAILED_NAMES=()
CURRENT_TEST=""
WORK=""

# ---------------------------------------------------------------- fixtures

# new_upstream NAME -- bare origin with one commit on 'main', plus an
# "author" work clone used to push further changes to it.
new_upstream() {
  local name=$1
  git init -q --bare -b main "$WORK/up/$name.git"
  git clone -q "$WORK/up/$name.git" "$WORK/authors/$name" 2>/dev/null
  git -C "$WORK/authors/$name" checkout -q -b main 2>/dev/null
  echo "initial" >"$WORK/authors/$name/README"
  git -C "$WORK/authors/$name" add -A
  git -C "$WORK/authors/$name" commit -qm "initial"
  git -C "$WORK/authors/$name" push -q origin main
}

# upstream_commit NAME [BRANCH] [FILE] -- add a commit upstream
upstream_commit() {
  local name=$1 branch=${2:-main} file=${3:-README}
  local a="$WORK/authors/$name"
  git -C "$a" checkout -q "$branch" 2>/dev/null || git -C "$a" checkout -q -b "$branch"
  echo "change-$RANDOM" >>"$a/$file"
  git -C "$a" add -A
  git -C "$a" commit -qm "update $file on $branch"
  git -C "$a" push -q origin "$branch"
}

# upstream_add_file NAME FILE CONTENT -- commit a brand new file on main
upstream_add_file() {
  local name=$1 file=$2 content=$3
  local a="$WORK/authors/$name"
  git -C "$a" checkout -q main
  printf '%s\n' "$content" >"$a/$file"
  git -C "$a" add -A
  git -C "$a" commit -qm "add $file"
  git -C "$a" push -q origin main
}

upstream_tag() {
  local name=$1 tag=$2
  git -C "$WORK/authors/$name" tag "$tag"
  git -C "$WORK/authors/$name" push -q origin "$tag"
}

upstream_delete_branch() {
  local name=$1 branch=$2
  git -C "$WORK/authors/$name" push -q origin --delete "$branch"
}

upstream_delete_tag() {
  local name=$1 tag=$2
  git -C "$WORK/authors/$name" push -q origin --delete "refs/tags/$tag"
}

# clone_repo CATEGORY NAME -- clone upstream into the library layout
clone_repo() {
  local cat=$1 name=$2
  mkdir -p "$WORK/lib/$cat"
  git clone -q "$WORK/up/$name.git" "$WORK/lib/$cat/$name"
}

repo() { echo "$WORK/lib/$1/$2"; }

run_pull() { "$PULL" "$@" >"$WORK/stdout" 2>"$WORK/stderr"; echo $? >"$WORK/exit"; }
pull_exit() { cat "$WORK/exit"; }
pull_out() { cat "$WORK/stdout" "$WORK/stderr"; }

# pull.sh's own structured report, free of git chatter and absolute paths --
# assert on this, never on pull_out, or fixture paths leak into the haystack.
pull_report() { cat "$WORK/stdout"; }
pull_anomalies() { grep '^!' "$WORK/stdout" || true; }

# Report lines with the given status prefix. Use this rather than a substring
# search: the summary line carries the words "skipped" and "failed" as counts.
pull_lines() { grep "^$1" "$WORK/stdout" || true; }

# ---------------------------------------------------------------- assertions

fail_test() {
  echo "    FAIL: $1"
  [ -n "${2:-}" ] && echo "      $2"
  FAIL_CURRENT=1
}

assert_eq() {
  local expected=$1 actual=$2 what=${3:-value}
  [ "$expected" = "$actual" ] && return 0
  fail_test "$what" "expected: [$expected]  actual: [$actual]"
}

assert_contains() {
  local haystack=$1 needle=$2 what=${3:-output}
  case "$haystack" in *"$needle"*) return 0;; esac
  fail_test "$what does not contain [$needle]" "got: $haystack"
}

assert_not_contains() {
  local haystack=$1 needle=$2 what=${3:-output}
  case "$haystack" in *"$needle"*) fail_test "$what unexpectedly contains [$needle]"; return;; esac
  return 0
}

assert_file_content() {
  local path=$1 expected=$2
  if [ ! -f "$path" ]; then fail_test "expected file missing: $path"; return; fi
  assert_eq "$expected" "$(cat "$path")" "content of $path"
}

assert_file_absent() {
  [ -e "$1" ] && fail_test "expected file to be absent: $1"
  return 0
}

# ---------------------------------------------------------------- runner

test_case() {
  CURRENT_TEST=$1
  if [ -n "${FILTER:-}" ]; then
    case "$CURRENT_TEST" in *"$FILTER"*) ;; *) return 1;; esac
  fi
  FAIL_CURRENT=0
  WORK="$TESTROOT/$CURRENT_TEST"
  mkdir -p "$WORK/up" "$WORK/authors" "$WORK/lib"
  echo "  - $CURRENT_TEST"
  return 0
}

end_case() {
  if [ "$FAIL_CURRENT" -eq 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$CURRENT_TEST")
  fi
}

# ================================================================ TESTS

echo "Running pull.sh tests"

# ---------------------------------------------------------------------------
if test_case "fetches_new_upstream_commits_into_remote_tracking"; then
  new_upstream alpha
  clone_repo tools alpha
  upstream_commit alpha
  expected=$(git -C "$WORK/authors/alpha" rev-parse main)

  run_pull "$WORK/lib"

  assert_eq "0" "$(pull_exit)" "exit code"
  assert_eq "$expected" "$(git -C "$(repo tools alpha)" rev-parse origin/main)" "origin/main"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "updates_checked_out_branch_and_working_tree"; then
  new_upstream alpha
  clone_repo tools alpha
  upstream_add_file alpha NOTES.md "hello from upstream"

  run_pull "$WORK/lib"

  assert_eq "0" "$(pull_exit)" "exit code"
  assert_file_content "$(repo tools alpha)/NOTES.md" "hello from upstream"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "fetches_new_tags"; then
  new_upstream alpha
  clone_repo tools alpha
  upstream_commit alpha
  upstream_tag alpha v9.9.9

  run_pull "$WORK/lib"

  assert_eq "v9.9.9" "$(git -C "$(repo tools alpha)" tag -l v9.9.9)" "tag v9.9.9 present"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "fetches_all_upstream_branches_not_just_default"; then
  new_upstream alpha
  clone_repo tools alpha
  upstream_commit alpha feature-x

  run_pull "$WORK/lib"

  assert_eq "origin/feature-x" \
    "$(git -C "$(repo tools alpha)" for-each-ref --format='%(refname:short)' refs/remotes/origin/feature-x)" \
    "origin/feature-x"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "processes_every_repo_across_categories"; then
  new_upstream alpha; new_upstream beta
  clone_repo tools alpha; clone_repo docs beta
  upstream_add_file alpha A.md "a"
  upstream_add_file beta B.md "b"

  run_pull "$WORK/lib"

  assert_file_content "$(repo tools alpha)/A.md" "a"
  assert_file_content "$(repo docs beta)/B.md" "b"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "discards_local_commits_and_reports_them"; then
  new_upstream alpha
  clone_repo tools alpha
  r=$(repo tools alpha)
  echo "agent scribble" >"$r/rogue.txt"
  git -C "$r" add -A
  git -C "$r" commit -qm "rogue commit by a confused agent"
  upstream_commit alpha

  run_pull "$WORK/lib"

  expected=$(git -C "$WORK/authors/alpha" rev-parse main)
  assert_eq "$expected" "$(git -C "$r" rev-parse HEAD)" "HEAD reset to upstream"
  assert_contains "$(pull_anomalies)" "local commit" "report of discarded local commits"
  assert_contains "$(pull_anomalies)" "tools/alpha" "report names the repo"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "discards_uncommitted_changes_and_reports_them"; then
  new_upstream alpha
  clone_repo tools alpha
  r=$(repo tools alpha)
  echo "half-finished agent edit" >"$r/README"
  upstream_commit alpha

  run_pull "$WORK/lib"

  assert_file_content "$r/README" "$(cat "$WORK/authors/alpha/README")"
  assert_contains "$(pull_anomalies)" "uncommitted" "report of discarded uncommitted changes"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "clobbers_untracked_file_blocking_the_update"; then
  new_upstream alpha
  clone_repo tools alpha
  r=$(repo tools alpha)
  echo "stale local copy" >"$r/NOTES.md"
  upstream_add_file alpha NOTES.md "authoritative upstream copy"

  run_pull "$WORK/lib"

  assert_eq "0" "$(pull_exit)" "exit code"
  assert_file_content "$r/NOTES.md" "authoritative upstream copy"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "preserves_untracked_files_that_do_not_conflict"; then
  new_upstream alpha
  clone_repo tools alpha
  r=$(repo tools alpha)
  echo "my research notes" >"$r/my-notes.txt"
  upstream_commit alpha

  run_pull "$WORK/lib"

  assert_file_content "$r/my-notes.txt" "my research notes"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "clean_repo_is_not_reported_as_an_anomaly"; then
  new_upstream alpha
  clone_repo tools alpha
  upstream_commit alpha

  run_pull "$WORK/lib"

  assert_eq "" "$(pull_anomalies)" "clean repo reports no anomalies"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "updates_local_branch_that_is_not_checked_out"; then
  new_upstream alpha
  upstream_commit alpha feature-x
  clone_repo tools alpha
  r=$(repo tools alpha)
  git -C "$r" branch feature-x origin/feature-x >/dev/null 2>&1
  upstream_commit alpha feature-x

  run_pull "$WORK/lib"

  expected=$(git -C "$WORK/authors/alpha" rev-parse feature-x)
  assert_eq "$expected" "$(git -C "$r" rev-parse feature-x)" "local feature-x"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "force_moves_diverged_local_branch_to_upstream"; then
  new_upstream alpha
  upstream_commit alpha feature-x
  clone_repo tools alpha
  r=$(repo tools alpha)
  git -C "$r" branch -f feature-x origin/main >/dev/null 2>&1   # point it somewhere wrong

  run_pull "$WORK/lib"

  expected=$(git -C "$WORK/authors/alpha" rev-parse feature-x)
  assert_eq "$expected" "$(git -C "$r" rev-parse feature-x)" "local feature-x realigned"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "deletes_local_branch_removed_upstream"; then
  new_upstream alpha
  upstream_commit alpha feature-x
  clone_repo tools alpha
  r=$(repo tools alpha)
  git -C "$r" branch feature-x origin/feature-x >/dev/null 2>&1
  upstream_delete_branch alpha feature-x

  run_pull "$WORK/lib"

  assert_eq "" "$(git -C "$r" for-each-ref --format='%(refname:short)' refs/heads/feature-x)" \
    "local feature-x removed"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "prunes_remote_tracking_ref_deleted_upstream"; then
  new_upstream alpha
  upstream_commit alpha feature-x
  clone_repo tools alpha
  upstream_delete_branch alpha feature-x

  run_pull "$WORK/lib"

  assert_eq "" \
    "$(git -C "$(repo tools alpha)" for-each-ref --format='%(refname:short)' refs/remotes/origin/feature-x)" \
    "origin/feature-x pruned"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "prunes_tag_deleted_upstream"; then
  new_upstream alpha
  upstream_tag alpha v1.0.0
  clone_repo tools alpha
  upstream_delete_tag alpha v1.0.0

  run_pull "$WORK/lib"

  assert_eq "" "$(git -C "$(repo tools alpha)" tag -l v1.0.0)" "tag v1.0.0 pruned"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "deletes_local_only_branch_and_reports_it"; then
  new_upstream alpha
  clone_repo tools alpha
  r=$(repo tools alpha)
  git -C "$r" branch agent-scratch >/dev/null 2>&1

  run_pull "$WORK/lib"

  assert_eq "" "$(git -C "$r" for-each-ref --format='%(refname:short)' refs/heads/agent-scratch)" \
    "agent-scratch removed"
  assert_contains "$(pull_anomalies)" "agent-scratch" "report of local-only branch"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "reattaches_detached_head_to_default_branch"; then
  new_upstream alpha
  clone_repo tools alpha
  r=$(repo tools alpha)
  git -C "$r" checkout -q --detach
  upstream_add_file alpha NOTES.md "upstream content"

  run_pull "$WORK/lib"

  assert_eq "0" "$(pull_exit)" "exit code"
  assert_eq "main" "$(git -C "$r" symbolic-ref --short -q HEAD)" "HEAD reattached"
  assert_file_content "$r/NOTES.md" "upstream content"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "recovers_when_checked_out_branch_is_deleted_upstream"; then
  new_upstream alpha
  upstream_commit alpha feature-x
  clone_repo tools alpha
  r=$(repo tools alpha)
  git -C "$r" checkout -q feature-x 2>/dev/null
  upstream_delete_branch alpha feature-x
  upstream_add_file alpha NOTES.md "back on main"

  run_pull "$WORK/lib"

  assert_eq "0" "$(pull_exit)" "exit code"
  assert_eq "main" "$(git -C "$r" symbolic-ref --short -q HEAD)" "HEAD moved to default branch"
  assert_file_content "$r/NOTES.md" "back on main"
  assert_eq "" "$(git -C "$r" for-each-ref --format='%(refname:short)' refs/heads/feature-x)" \
    "stale feature-x removed"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "unreachable_remote_fails_without_stopping_other_repos"; then
  new_upstream alpha; new_upstream beta
  clone_repo tools alpha; clone_repo docs beta
  git -C "$(repo tools alpha)" remote set-url origin "$WORK/up/does-not-exist.git"
  upstream_add_file beta B.md "beta still updated"

  run_pull "$WORK/lib"

  assert_eq "1" "$(pull_exit)" "exit code"
  assert_contains "$(pull_report)" "failed" "failure reported"
  assert_contains "$(pull_report)" "tools/alpha" "failing repo named"
  assert_file_content "$(repo docs beta)/B.md" "beta still updated"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "repo_without_origin_is_reported_as_failure"; then
  new_upstream beta
  clone_repo docs beta
  mkdir -p "$WORK/lib/tools/orphan"
  git init -q -b main "$WORK/lib/tools/orphan"
  echo x >"$WORK/lib/tools/orphan/x"
  git -C "$WORK/lib/tools/orphan" add -A
  git -C "$WORK/lib/tools/orphan" commit -qm "no remote here"
  upstream_add_file beta B.md "beta ok"

  run_pull "$WORK/lib"

  assert_eq "1" "$(pull_exit)" "exit code"
  assert_contains "$(pull_report)" "tools/orphan" "orphan repo named"
  assert_file_content "$(repo docs beta)/B.md" "beta ok"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "dry_run_changes_nothing"; then
  new_upstream alpha
  clone_repo tools alpha
  r=$(repo tools alpha)
  before=$(git -C "$r" rev-parse origin/main)
  upstream_add_file alpha NOTES.md "should not arrive"

  run_pull -n "$WORK/lib"

  assert_eq "0" "$(pull_exit)" "exit code"
  assert_eq "$before" "$(git -C "$r" rev-parse origin/main)" "origin/main untouched"
  assert_file_absent "$r/NOTES.md"
  assert_contains "$(pull_report)" "tools/alpha" "dry run still lists the repo"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "summary_counts_repos_and_failures"; then
  new_upstream alpha; new_upstream beta
  clone_repo tools alpha; clone_repo docs beta
  git -C "$(repo tools alpha)" remote set-url origin "$WORK/up/does-not-exist.git"

  run_pull "$WORK/lib"

  assert_contains "$(pull_report)" "2 repos" "summary repo count"
  assert_contains "$(pull_report)" "1 failed" "summary failure count"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "parallel_jobs_update_every_repo"; then
  for n in alpha beta gamma delta; do new_upstream "$n"; clone_repo tools "$n"; done
  for n in alpha beta gamma delta; do upstream_add_file "$n" "$n.md" "content-$n"; done

  run_pull -j 4 "$WORK/lib"

  assert_eq "0" "$(pull_exit)" "exit code"
  for n in alpha beta gamma delta; do
    assert_file_content "$(repo tools "$n")/$n.md" "content-$n"
  done
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "parallel_output_is_not_interleaved"; then
  for n in alpha beta gamma delta; do new_upstream "$n"; clone_repo tools "$n"; done

  run_pull -j 4 "$WORK/lib"

  # Every status line must name exactly one repo, on its own line.
  malformed=$(grep -c '^ok .*ok ' "$WORK/stdout" || true)
  assert_eq "0" "$malformed" "spliced status lines"
  assert_eq "4" "$(grep -c '^ok' "$WORK/stdout" || true)" "one status line per repo"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "defaults_root_to_script_location"; then
  new_upstream alpha
  clone_repo tools alpha
  cp "$PULL" "$WORK/lib/pull.sh"
  upstream_add_file alpha NOTES.md "found without an argument"

  (cd / && bash "$WORK/lib/pull.sh" >"$WORK/stdout" 2>"$WORK/stderr"); echo $? >"$WORK/exit"

  assert_eq "0" "$(pull_exit)" "exit code"
  assert_file_content "$(repo tools alpha)/NOTES.md" "found without an argument"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "help_flag_prints_usage_and_exits_zero"; then
  run_pull -h

  assert_eq "0" "$(pull_exit)" "exit code"
  assert_contains "$(pull_report)" "Usage" "usage text"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "unknown_option_is_rejected"; then
  run_pull --nonsense

  assert_eq "2" "$(pull_exit)" "exit code"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "successful_run_writes_nothing_to_stderr"; then
  new_upstream alpha
  clone_repo tools alpha
  upstream_commit alpha

  run_pull "$WORK/lib"

  assert_eq "0" "$(pull_exit)" "exit code"
  assert_eq "" "$(cat "$WORK/stderr")" "stderr on a clean run"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "dry_run_writes_nothing_to_stderr"; then
  new_upstream alpha
  clone_repo tools alpha

  run_pull -n "$WORK/lib"

  assert_eq "" "$(cat "$WORK/stderr")" "stderr on a dry run"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "reports_directory_that_is_not_a_repository"; then
  new_upstream alpha
  clone_repo tools alpha
  mkdir -p "$WORK/lib/tools/some-tarball"
  echo "unpacked source" >"$WORK/lib/tools/some-tarball/README"

  run_pull "$WORK/lib"

  assert_eq "0" "$(pull_exit)" "exit code"
  assert_contains "$(pull_report)" "skipped" "skipped line present"
  assert_contains "$(pull_report)" "tools/some-tarball" "skipped directory named"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "skipped_directory_is_not_counted_as_a_repo"; then
  new_upstream alpha
  clone_repo tools alpha
  mkdir -p "$WORK/lib/tools/some-tarball"

  run_pull "$WORK/lib"

  assert_contains "$(pull_report)" "1 repos" "repo count excludes the tarball"
  assert_contains "$(pull_report)" "1 other directory skipped" "non-repo directories counted separately"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "does_not_report_directories_inside_a_repository"; then
  new_upstream alpha; new_upstream nested
  clone_repo tools alpha
  r=$(repo tools alpha)
  mkdir -p "$r/docs"                       # plain directory inside a repo
  echo notes >"$r/docs/notes.md"
  git clone -q "$WORK/up/nested.git" "$r/vendored"   # repo inside a repo

  run_pull "$WORK/lib"

  assert_not_contains "$(pull_report)" "docs" "plain dir inside a repo is not skipped-reported"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "dry_run_reports_skipped_directories"; then
  new_upstream alpha
  clone_repo tools alpha
  mkdir -p "$WORK/lib/tools/some-tarball"

  run_pull -n "$WORK/lib"

  assert_contains "$(pull_report)" "tools/some-tarball" "skipped directory named in dry run"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "no_skipped_line_when_every_directory_is_a_repo"; then
  new_upstream alpha
  clone_repo tools alpha

  run_pull "$WORK/lib"

  assert_eq "" "$(pull_lines skipped)" "no skipped lines"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "skips_repo_with_a_git_lock_file"; then
  new_upstream alpha
  clone_repo tools alpha
  r=$(repo tools alpha)
  before=$(git -C "$r" rev-parse origin/main)
  touch "$r/.git/index.lock"
  upstream_add_file alpha NOTES.md "must not arrive"

  run_pull "$WORK/lib"

  assert_eq "0" "$(pull_exit)" "exit code"
  assert_eq "$before" "$(git -C "$r" rev-parse origin/main)" "locked repo left alone"
  assert_file_absent "$r/NOTES.md"
  assert_contains "$(pull_report)" "skipped" "skip reported"
  assert_contains "$(pull_report)" "tools/alpha" "locked repo named"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "skips_repo_with_pack_transfer_in_progress"; then
  new_upstream alpha
  clone_repo tools alpha
  r=$(repo tools alpha)
  before=$(git -C "$r" rev-parse origin/main)
  mkdir -p "$r/.git/objects/pack"
  touch "$r/.git/objects/pack/tmp_pack_abc123"
  upstream_add_file alpha NOTES.md "must not arrive"

  run_pull "$WORK/lib"

  assert_eq "0" "$(pull_exit)" "exit code"
  assert_eq "$before" "$(git -C "$r" rev-parse origin/main)" "mid-clone repo left alone"
  assert_contains "$(pull_report)" "tools/alpha" "mid-clone repo named"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "skips_repo_whose_head_does_not_resolve"; then
  new_upstream alpha; new_upstream beta
  clone_repo docs beta
  # An interrupted clone: origin configured, objects not yet written.
  mkdir -p "$WORK/lib/tools/half-cloned"
  git init -q -b main "$WORK/lib/tools/half-cloned"
  git -C "$WORK/lib/tools/half-cloned" remote add origin "$WORK/up/alpha.git"
  upstream_add_file beta B.md "beta still updated"

  run_pull "$WORK/lib"

  assert_eq "0" "$(pull_exit)" "exit code"
  assert_contains "$(pull_report)" "skipped  tools/half-cloned" "incomplete repo skipped, not failed"
  assert_eq "" "$(pull_lines failed)" "no failure lines"
  assert_file_content "$(repo docs beta)/B.md" "beta still updated"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "skipped_repo_is_not_counted_as_failure"; then
  new_upstream alpha
  clone_repo tools alpha
  touch "$(repo tools alpha)/.git/index.lock"

  run_pull "$WORK/lib"

  assert_eq "0" "$(pull_exit)" "exit code"
  assert_contains "$(pull_report)" "0 failed" "not counted as a failure"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "root_repository_is_never_touched"; then
  new_upstream alpha
  clone_repo tools alpha
  # ROOT itself is a workspace repo holding the script.
  git init -q -b main "$WORK/lib"
  echo "the script" >"$WORK/lib/pull.sh"
  git -C "$WORK/lib" add pull.sh
  git -C "$WORK/lib" commit -qm "my own work"
  root_head=$(git -C "$WORK/lib" rev-parse HEAD)
  echo "uncommitted edit" >>"$WORK/lib/pull.sh"
  upstream_add_file alpha NOTES.md "child updated"

  run_pull "$WORK/lib"

  assert_eq "$root_head" "$(git -C "$WORK/lib" rev-parse HEAD)" "root HEAD untouched"
  assert_contains "$(cat "$WORK/lib/pull.sh")" "uncommitted edit" "root working tree untouched"
  assert_file_content "$(repo tools alpha)/NOTES.md" "child updated"
  assert_contains "$(pull_report)" "1 repos" "root not counted as a mirror"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "root_repository_does_not_appear_in_the_report"; then
  new_upstream alpha
  clone_repo tools alpha
  git init -q -b main "$WORK/lib"

  run_pull "$WORK/lib"

  assert_not_contains "$(pull_report)" "$WORK" "absolute root path leaked into report"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "root_repository_is_excluded_given_a_trailing_slash"; then
  new_upstream alpha
  clone_repo tools alpha
  git init -q -b main "$WORK/lib"
  echo "the script" >"$WORK/lib/pull.sh"
  git -C "$WORK/lib" add pull.sh
  git -C "$WORK/lib" commit -qm "my own work"
  root_head=$(git -C "$WORK/lib" rev-parse HEAD)

  run_pull "$WORK/lib/"

  assert_eq "$root_head" "$(git -C "$WORK/lib" rev-parse HEAD)" "root HEAD untouched"
  assert_contains "$(pull_report)" "1 repos" "root not counted as a mirror"
  end_case
fi

# ---------------------------------------------------------------------------
if test_case "relative_root_path_is_accepted"; then
  new_upstream alpha
  clone_repo tools alpha
  upstream_add_file alpha NOTES.md "reached via relative path"

  (cd "$WORK" && "$PULL" lib >"$WORK/stdout" 2>"$WORK/stderr"); echo $? >"$WORK/exit"

  assert_eq "0" "$(pull_exit)" "exit code"
  assert_file_content "$(repo tools alpha)/NOTES.md" "reached via relative path"
  assert_contains "$(pull_report)" "tools/alpha" "repo named by relative path"
  end_case
fi

# ================================================================ summary

rm -rf "$TESTROOT"

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'failing: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
