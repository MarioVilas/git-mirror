#!/usr/bin/env bash
# Shared test harness: fixtures, assertions and the runner.
#
# Sourced by pull_test.sh and export_test.sh. Set SUITE to a short name before
# sourcing so each suite gets its own scratch directory.
#
# Every fixture is built from scratch under $TMPDIR: bare "upstream"
# repositories plus clones of each supported shape. No test touches a real
# repository.

TESTROOT="${TMPDIR:-/tmp}/${SUITE:-suite}-tests.$$"

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

# A file:// URL -- required for --depth, which is ignored for local path clones.
up_url() { echo "file://$WORK/up/$1.git"; }

# Alternative clone shapes the tools must detect and preserve.
clone_repo_shallow() {
  local cat=$1 name=$2
  mkdir -p "$WORK/lib/$cat"
  git clone -q --depth 1 "$(up_url "$name")" "$WORK/lib/$cat/$name"
}

clone_repo_single_branch() {
  local cat=$1 name=$2
  mkdir -p "$WORK/lib/$cat"
  git clone -q --single-branch "$(up_url "$name")" "$WORK/lib/$cat/$name"
}

clone_repo_partial() {
  local cat=$1 name=$2
  mkdir -p "$WORK/lib/$cat"
  git -C "$WORK/up/$name.git" config uploadpack.allowFilter true
  git clone -q --filter=blob:none "$(up_url "$name")" "$WORK/lib/$cat/$name"
}

clone_repo_bare() {
  local cat=$1 name=$2 dir=${3:-$2.git}
  mkdir -p "$WORK/lib/$cat"
  git clone -q --bare "$(up_url "$name")" "$WORK/lib/$cat/$dir"
}

clone_repo_mirror() {
  local cat=$1 name=$2 dir=${3:-$2.git}
  mkdir -p "$WORK/lib/$cat"
  git clone -q --mirror "$(up_url "$name")" "$WORK/lib/$cat/$dir"
}

repo() { echo "$WORK/lib/$1/$2"; }

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

finish_tests() {
  rm -rf "$TESTROOT"
  echo
  echo "passed: $PASS   failed: $FAIL"
  if [ "$FAIL" -gt 0 ]; then
    printf 'failing: %s\n' "${FAILED_NAMES[*]}"
    exit 1
  fi
  exit 0
}
