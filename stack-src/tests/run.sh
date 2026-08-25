#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT_DIR=$(cd "$SOURCE_DIR/.." && pwd)
STACK_CHECK="$ROOT_DIR/stack-check.com"
STACK_PUSH="$ROOT_DIR/stack-push.com"
REAL_GIT=$(command -v git)
SUITE_DIR=$(mktemp -d /tmp/stack-tools-tests.XXXXXX)
if [[ ${KEEP_TEST_REPOS:-0} != 1 ]]; then
  trap 'find "$SUITE_DIR" -depth -delete' EXIT
fi

CASES=0
ASSERTIONS=0
FAILURES=0
CASE_NAME=
CASE_DIR=
WORK=
REMOTE=
OUTPUT=
LAST_STATUS=0

start_case() {
  CASE_NAME=$1
  ((CASES += 1))
  printf '\n[%02d] %s\n' "$CASES" "$CASE_NAME"
}

new_repo() {
  CASE_DIR="$SUITE_DIR/case-$CASES"
  WORK="$CASE_DIR/work"
  REMOTE="$CASE_DIR/remote.git"
  OUTPUT="$CASE_DIR/output"
  mkdir -p "$CASE_DIR"
  "$REAL_GIT" init --bare -q "$REMOTE"
  "$REAL_GIT" clone -q "$REMOTE" "$WORK" 2>/dev/null
  "$REAL_GIT" -C "$WORK" config user.name "Stack Tests"
  "$REAL_GIT" -C "$WORK" config user.email "stack-tests@example.com"
  printf 'base\n' > "$WORK/base"
  "$REAL_GIT" -C "$WORK" add base
  "$REAL_GIT" -C "$WORK" commit -qm base
  "$REAL_GIT" -C "$WORK" branch -M master
  "$REAL_GIT" -C "$WORK" push -qu origin master
  "$REAL_GIT" -C "$WORK" remote set-head origin master
}

commit_file() {
  local file=$1 content=$2 message=$3
  printf '%s\n' "$content" > "$WORK/$file"
  "$REAL_GIT" -C "$WORK" add "$file"
  "$REAL_GIT" -C "$WORK" commit -qm "$message"
}

push_branch() {
  "$REAL_GIT" -C "$WORK" push -qu origin "${1:-HEAD}"
}

run_push() {
  if (cd "$WORK" && "$STACK_PUSH" "$@") >"$OUTPUT" 2>&1; then
    LAST_STATUS=0
  else
    LAST_STATUS=$?
  fi
}

run_push_without_tty() {
  if (cd "$WORK" && "$STACK_PUSH" "$@" </dev/null) >"$OUTPUT" 2>&1; then
    LAST_STATUS=0
  else
    LAST_STATUS=$?
  fi
}

run_check() {
  local record=$1
  shift
  if printf '%s\n' "$record" |
      (cd "$WORK" && "$STACK_CHECK" "$@") >"$OUTPUT" 2>&1; then
    LAST_STATUS=0
  else
    LAST_STATUS=$?
  fi
}

check_status() {
  local expected=$1
  ((ASSERTIONS += 1))
  if [[ $LAST_STATUS -ne $expected ]]; then
    printf '  FAIL: expected status %s, got %s\n' "$expected" "$LAST_STATUS"
    sed 's/^/        /' "$OUTPUT"
    ((FAILURES += 1))
  fi
}

check_output() {
  local expected=$1
  ((ASSERTIONS += 1))
  if ! rg -Fq -- "$expected" "$OUTPUT"; then
    printf '  FAIL: output does not contain: %s\n' "$expected"
    sed 's/^/        /' "$OUTPUT"
    ((FAILURES += 1))
  fi
}

check_no_output() {
  local rejected=$1
  ((ASSERTIONS += 1))
  if rg -Fq -- "$rejected" "$OUTPUT"; then
    printf '  FAIL: output unexpectedly contains: %s\n' "$rejected"
    sed 's/^/        /' "$OUTPUT"
    ((FAILURES += 1))
  fi
}

check_equal() {
  local actual=$1 expected=$2 description=$3
  ((ASSERTIONS += 1))
  if [[ $actual != "$expected" ]]; then
    printf '  FAIL: %s\n        expected: %s\n        actual:   %s\n' \
      "$description" "$expected" "$actual"
    ((FAILURES += 1))
  fi
}

check_ancestor() {
  local ancestor=$1 descendant=$2 description=$3
  ((ASSERTIONS += 1))
  if ! "$REAL_GIT" --git-dir="$REMOTE" merge-base --is-ancestor \
      "refs/heads/$ancestor" "refs/heads/$descendant"; then
    printf '  FAIL: %s is not an ancestor of %s (%s)\n' \
      "$ancestor" "$descendant" "$description"
    ((FAILURES += 1))
  fi
}

check_not_ancestor() {
  local ancestor=$1 descendant=$2 description=$3
  ((ASSERTIONS += 1))
  if "$REAL_GIT" --git-dir="$REMOTE" merge-base --is-ancestor \
      "$ancestor" "refs/heads/$descendant"; then
    printf '  FAIL: %s remains an ancestor of %s (%s)\n' \
      "$ancestor" "$descendant" "$description"
    ((FAILURES += 1))
  fi
}

start_case "help and direct stack-check invocation"
OUTPUT="$SUITE_DIR/help-output"
if "$STACK_PUSH" --help >"$OUTPUT" 2>&1; then LAST_STATUS=0; else LAST_STATUS=$?; fi
check_status 0
check_output "-y, --yes"
check_output "-f, --force"
check_output "--no-fetch"
check_output "--remote=NAME"
check_output "--base=BRANCH"
check_output "--release-branches=LIST"
check_output "default: dev test release master main"
check_output "Active remote branches: last 2 months"
if timeout 3 script -qfec "$STACK_CHECK" /dev/null >"$OUTPUT" 2>&1; then
  LAST_STATUS=0
else
  LAST_STATUS=$?
fi
check_status 1
check_output "expects Git pre-push records on stdin"

start_case "tag-only and malformed pre-push input"
new_repo
zero=0000000000000000000000000000000000000000
run_check "refs/tags/v1 $zero refs/tags/v1 $zero" --no-fetch origin
check_status 0
check_output "No branch updates to check."
run_check "malformed record" --no-fetch origin
check_status 1
check_output "malformed pre-push record on line 1"

start_case "stack-check reports clean and broken stacks"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file a a0 A0
push_branch feature-a
"$REAL_GIT" -C "$WORK" checkout -qb feature-b
commit_file b b0 B0
push_branch feature-b
tip_a=$("$REAL_GIT" -C "$WORK" rev-parse feature-a)
remote_a=$("$REAL_GIT" -C "$WORK" rev-parse origin/feature-a)
run_check "refs/heads/feature-a $tip_a refs/heads/feature-a $remote_a" --no-fetch origin
check_status 0
check_output "No branches need restacking."
"$REAL_GIT" -C "$WORK" checkout -q feature-a
"$REAL_GIT" -C "$WORK" reset -q --hard master
commit_file a a1 A1
tip_a=$("$REAL_GIT" -C "$WORK" rev-parse feature-a)
run_check "refs/heads/feature-a $tip_a refs/heads/feature-a $remote_a" --no-fetch origin
check_status 1
check_output "feature-b must be restacked onto feature-a"
check_output "no interactive terminal is available"

start_case "clean stack-push progress"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file a a A
push_branch feature-a
run_push -y feature-a
check_status 0
check_output "Fetching branches from origin..."
check_output "Checking branch stack against origin/master..."
check_output "No branches need restacking."
check_output "Pushing 1 branch(es) to origin..."
check_output "Push completed."

start_case "current branch and master fallback work without remote HEAD"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file a a0 A0
push_branch feature-a
"$REAL_GIT" -C "$WORK" remote set-head origin -d
commit_file a a1 A1
run_push -y --no-fetch
check_status 0
check_output "Checking branch stack against origin/master..."
check_equal "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse refs/heads/feature-a)" \
  "$("$REAL_GIT" -C "$WORK" rev-parse feature-a)" \
  "current branch was not pushed with fallback base detection"

start_case "default release branches are excluded"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file a a0 A0
push_branch feature-a
"$REAL_GIT" -C "$WORK" checkout -qb test
commit_file test test0 test0
push_branch test
remote_test=$("$REAL_GIT" -C "$WORK" rev-parse origin/test)
"$REAL_GIT" -C "$WORK" checkout -q feature-a
"$REAL_GIT" -C "$WORK" reset -q --hard master
commit_file a a1 A1
run_push -y -f --no-fetch feature-a
check_status 0
check_no_output "test must be restacked"
check_equal "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse refs/heads/test)" \
  "$remote_test" "excluded test branch moved"

start_case "remote history cannot be removed without force"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file old-a a0 A0
push_branch feature-a
remote_a=$("$REAL_GIT" -C "$WORK" rev-parse origin/feature-a)
"$REAL_GIT" -C "$WORK" reset -q --hard master
commit_file new-a a1 A1
run_push -y --no-fetch feature-a
check_status 1
check_output "would remove commits from origin/feature-a"
check_output "rerun with --force if intentional"
check_equal "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse refs/heads/feature-a)" \
  "$remote_a" "remote history changed without --force"

start_case "one omitted child is restacked"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file a a0 A0
push_branch feature-a
"$REAL_GIT" -C "$WORK" checkout -qb feature-b
commit_file b b0 B0
push_branch feature-b
"$REAL_GIT" -C "$WORK" checkout -q feature-a
"$REAL_GIT" -C "$WORK" reset -q --hard master
commit_file a a1 A1
run_push -y -f --no-fetch feature-a
check_status 0
check_output "feature-b must be restacked onto feature-a"
check_output "Rebasing feature-b onto feature-a"
check_ancestor feature-a feature-b "omitted child restack"

start_case "dry run reports the stack without changing local or remote tips"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file a a0 A0
push_branch feature-a
remote_a=$("$REAL_GIT" -C "$WORK" rev-parse origin/feature-a)
"$REAL_GIT" -C "$WORK" checkout -qb feature-b
commit_file b b0 B0
push_branch feature-b
local_b=$("$REAL_GIT" -C "$WORK" rev-parse feature-b)
"$REAL_GIT" -C "$WORK" checkout -q feature-a
"$REAL_GIT" -C "$WORK" reset -q --hard master
commit_file a a1 A1
run_push --dry-run -f --no-fetch feature-a
check_status 0
check_output "feature-a depends on master (requested)"
check_output "feature-b depends on feature-a"
check_output "Dry run complete; no local branches were changed and nothing was pushed."
check_equal "$("$REAL_GIT" -C "$WORK" rev-parse feature-b)" \
  "$local_b" "dry run changed the omitted child"
check_equal "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse refs/heads/feature-a)" \
  "$remote_a" "dry run changed the requested remote branch"

start_case "old requested parent retains its recent descendant"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
old_date=$(date --date='4 months ago' --iso-8601=seconds)
GIT_AUTHOR_DATE=$old_date GIT_COMMITTER_DATE=$old_date commit_file a a0 A0
push_branch feature-a
"$REAL_GIT" -C "$WORK" checkout -qb feature-b
commit_file b b0 B0
push_branch feature-b
"$REAL_GIT" -C "$WORK" checkout -q feature-a
"$REAL_GIT" -C "$WORK" reset -q --hard master
commit_file a a1 A1
run_push -y -f --no-fetch feature-a
check_status 0
check_output "Rebasing feature-b onto feature-a"
check_ancestor feature-a feature-b "recent child of old requested parent"

start_case "already-restacked omitted child stays silent but is pushed"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file a a0 A0
old_a=$("$REAL_GIT" -C "$WORK" rev-parse HEAD)
push_branch feature-a
"$REAL_GIT" -C "$WORK" checkout -qb feature-b
commit_file b b0 B0
push_branch feature-b
"$REAL_GIT" -C "$WORK" checkout -q feature-a
"$REAL_GIT" -C "$WORK" reset -q --hard master
commit_file a a1 A1
new_a=$("$REAL_GIT" -C "$WORK" rev-parse HEAD)
"$REAL_GIT" -C "$WORK" checkout -q feature-b
"$REAL_GIT" -C "$WORK" rebase -q --onto "$new_a" "$old_a"
local_b=$("$REAL_GIT" -C "$WORK" rev-parse HEAD)
run_push_without_tty -f --no-fetch feature-a
check_status 0
check_output "No branches need restacking."
check_no_output "Rebasing feature-b"
check_equal "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse refs/heads/feature-b)" \
  "$local_b" "already-restacked child was not pushed"

start_case "a merge containing old and new parent histories is replayed"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file old-a a0 A0
old_a=$("$REAL_GIT" -C "$WORK" rev-parse HEAD)
push_branch feature-a
"$REAL_GIT" -C "$WORK" checkout -qb feature-b
commit_file b b0 B0
push_branch feature-b
"$REAL_GIT" -C "$WORK" checkout -q feature-a
"$REAL_GIT" -C "$WORK" reset -q --hard master
commit_file new-a a1 A1
new_a=$("$REAL_GIT" -C "$WORK" rev-parse HEAD)
"$REAL_GIT" -C "$WORK" checkout -q feature-b
"$REAL_GIT" -C "$WORK" merge -q --no-ff -m "merge rewritten parent" "$new_a"
run_push -y -f --no-fetch feature-a
check_status 0
check_output "Rebasing feature-b onto feature-a"
check_ancestor feature-a feature-b "merged old and new parent histories"
check_not_ancestor "$old_a" feature-b "obsolete parent history"

start_case "linear A to B to C stack is repaired completely"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file a a0 A0
push_branch feature-a
"$REAL_GIT" -C "$WORK" checkout -qb feature-b
commit_file b b0 B0
push_branch feature-b
"$REAL_GIT" -C "$WORK" checkout -qb feature-c
commit_file c c0 C0
push_branch feature-c
"$REAL_GIT" -C "$WORK" checkout -q feature-a
"$REAL_GIT" -C "$WORK" reset -q --hard master
commit_file a a1 A1
run_push -y -f --no-fetch feature-a
check_status 0
check_ancestor feature-a feature-b "first repaired edge"
check_ancestor feature-b feature-c "propagated repaired edge"
check_output "Rebasing feature-c onto feature-b"

start_case "branching descendants C and D are repaired after B"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file a a0 A0
push_branch feature-a
"$REAL_GIT" -C "$WORK" checkout -qb feature-b
commit_file b b0 B0
push_branch feature-b
"$REAL_GIT" -C "$WORK" checkout -qb feature-c
commit_file c c0 C0
push_branch feature-c
"$REAL_GIT" -C "$WORK" checkout -qb feature-d feature-b
commit_file d d0 D0
push_branch feature-d
"$REAL_GIT" -C "$WORK" checkout -q feature-a
"$REAL_GIT" -C "$WORK" reset -q --hard master
commit_file a a1 A1
run_push -y -f --no-fetch feature-a
check_status 0
check_ancestor feature-a feature-b "branching parent"
check_ancestor feature-b feature-c "first branching child"
check_ancestor feature-b feature-d "second branching child"

start_case "missing omitted child is created and restacked"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file a a0 A0
push_branch feature-a
"$REAL_GIT" -C "$WORK" checkout -qb feature-b
commit_file b b0 B0
push_branch feature-b
"$REAL_GIT" -C "$WORK" checkout -q feature-a
"$REAL_GIT" -C "$WORK" branch -D feature-b >/dev/null
"$REAL_GIT" -C "$WORK" reset -q --hard master
commit_file a a1 A1
run_push -y -f --no-fetch feature-a
check_status 0
check_output "Creating local branch feature-b from origin/feature-b"
check_ancestor feature-a feature-b "created omitted child"

start_case "dirty worktree blocks a required restack"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file a a0 A0
push_branch feature-a
"$REAL_GIT" -C "$WORK" checkout -qb feature-b
commit_file b b0 B0
push_branch feature-b
"$REAL_GIT" -C "$WORK" checkout -q feature-a
"$REAL_GIT" -C "$WORK" reset -q --hard master
commit_file a a1 A1
printf 'dirty\n' > "$WORK/untracked"
run_push -y -f --no-fetch feature-a
check_status 1
check_output "automatic restacking requires a clean working tree"

start_case "partial rebase failure reports retained local changes"
new_repo
"$REAL_GIT" -C "$WORK" config rerere.enabled false
printf 'base\n' > "$WORK/shared"
"$REAL_GIT" -C "$WORK" add shared
"$REAL_GIT" -C "$WORK" commit -qm shared-base
"$REAL_GIT" -C "$WORK" push -qu origin master
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
printf 'a0\n' > "$WORK/shared"
"$REAL_GIT" -C "$WORK" commit -qam A0
old_a=$("$REAL_GIT" -C "$WORK" rev-parse HEAD)
push_branch feature-a
"$REAL_GIT" -C "$WORK" checkout -qb feature-b
commit_file b b0 B0
push_branch feature-b
remote_b=$("$REAL_GIT" -C "$WORK" rev-parse HEAD)
"$REAL_GIT" -C "$WORK" checkout -qb feature-c "$old_a"
printf 'c0\n' > "$WORK/shared"
"$REAL_GIT" -C "$WORK" commit -qam C0
push_branch feature-c
"$REAL_GIT" -C "$WORK" checkout -q feature-a
"$REAL_GIT" -C "$WORK" reset -q --hard master
printf 'a1\n' > "$WORK/shared"
"$REAL_GIT" -C "$WORK" commit -qam A1
run_push -y -f --no-fetch feature-a
check_status 1
check_output "rebase of feature-c failed"
check_output "local changes remain on feature-b"
check_output "The remote push has not started."
check_equal "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse refs/heads/feature-b)" \
  "$remote_b" "remote changed before a conflicting restack completed"

start_case "atomic rejection preserves the remote and reports local recovery"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file old-a a0 A0
push_branch feature-a
remote_a=$("$REAL_GIT" -C "$WORK" rev-parse HEAD)
"$REAL_GIT" -C "$WORK" checkout -qb feature-b
commit_file b b0 B0
push_branch feature-b
remote_b=$("$REAL_GIT" -C "$WORK" rev-parse HEAD)
"$REAL_GIT" --git-dir="$REMOTE" config receive.denyNonFastForwards true
"$REAL_GIT" -C "$WORK" checkout -q feature-a
"$REAL_GIT" -C "$WORK" reset -q --hard master
commit_file new-a a1 A1
run_push -y -f --no-fetch feature-a
check_status 1
check_output "local changes remain on feature-b"
check_output "atomic stack push failed"
check_equal "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse refs/heads/feature-a)" \
  "$remote_a" "atomic rejection changed feature-a"
check_equal "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse refs/heads/feature-b)" \
  "$remote_b" "atomic rejection changed feature-b"

start_case "remote arrival during fetch invalidates pre-stacked descendants"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file a a0 A0
old_a=$("$REAL_GIT" -C "$WORK" rev-parse HEAD)
push_branch feature-a
"$REAL_GIT" -C "$WORK" checkout -qb feature-b
commit_file b b0 B0
push_branch feature-b
"$REAL_GIT" -C "$WORK" checkout -q feature-a
commit_file local local-a local-A
local_a=$("$REAL_GIT" -C "$WORK" rev-parse HEAD)
"$REAL_GIT" -C "$WORK" checkout -q feature-b
"$REAL_GIT" -C "$WORK" rebase -q --onto "$local_a" "$old_a"
"$REAL_GIT" clone -q "$REMOTE" "$CASE_DIR/racer"
"$REAL_GIT" -C "$CASE_DIR/racer" config user.name "Stack Racer"
"$REAL_GIT" -C "$CASE_DIR/racer" config user.email "racer@example.com"
"$REAL_GIT" -C "$CASE_DIR/racer" checkout -q feature-a
printf 'remote\n' > "$CASE_DIR/racer/remote"
"$REAL_GIT" -C "$CASE_DIR/racer" add remote
"$REAL_GIT" -C "$CASE_DIR/racer" commit -qm remote-A
race_sha=$("$REAL_GIT" -C "$CASE_DIR/racer" rev-parse HEAD)
"$REAL_GIT" -C "$CASE_DIR/racer" push -qu origin HEAD:test
mkdir -p "$CASE_DIR/bin"
cat > "$CASE_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
set -e
if [[ ${1:-} == fetch && ! -e "$STACK_RACE_MARKER" ]]; then
  touch "$STACK_RACE_MARKER"
  "$STACK_REAL_GIT" --git-dir="$STACK_RACE_REMOTE" update-ref \
    refs/heads/feature-a "$STACK_RACE_SHA"
fi
exec "$STACK_REAL_GIT" "$@"
EOF
chmod +x "$CASE_DIR/bin/git"
if (cd "$WORK" && env \
    PATH="$CASE_DIR/bin:$PATH" \
    STACK_REAL_GIT="$REAL_GIT" \
    STACK_RACE_MARKER="$CASE_DIR/raced" \
    STACK_RACE_REMOTE="$REMOTE" \
    STACK_RACE_SHA="$race_sha" \
    "$STACK_PUSH" -y -f --remote=origin feature-a) >"$OUTPUT" 2>&1; then
  LAST_STATUS=0
else
  LAST_STATUS=$?
fi
check_status 0
check_output "received remote commits during fetch"
check_ancestor feature-a feature-b "descendant after parent fetch replay"

start_case "indeterminate push failure does not claim the remote is unchanged"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file a a0 A0
push_branch feature-a
commit_file a a1 A1
local_a=$("$REAL_GIT" -C "$WORK" rev-parse HEAD)
mkdir -p "$CASE_DIR/bin"
cat > "$CASE_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
set -e
if [[ ${1:-} == push && ! -e "$STACK_PUSH_MARKER" ]]; then
  touch "$STACK_PUSH_MARKER"
  "$STACK_REAL_GIT" "$@"
  exit 1
fi
exec "$STACK_REAL_GIT" "$@"
EOF
chmod +x "$CASE_DIR/bin/git"
if (cd "$WORK" && env \
    PATH="$CASE_DIR/bin:$PATH" \
    STACK_REAL_GIT="$REAL_GIT" \
    STACK_PUSH_MARKER="$CASE_DIR/pushed" \
    "$STACK_PUSH" -y --no-fetch feature-a) >"$OUTPUT" 2>&1; then
  LAST_STATUS=0
else
  LAST_STATUS=$?
fi
check_status 1
check_equal "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse refs/heads/feature-a)" \
  "$local_a" "push wrapper did not update the remote before losing acknowledgement"
check_output "remote outcome is unknown"
check_no_output "no remote branches were updated"

start_case "duplicate and missing requested branches are named"
new_repo
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file a a A
run_push --no-fetch feature-a feature-a
check_status 1
check_output "feature-a was requested more than once"
run_push --no-fetch missing-branch
check_status 1
check_output "requested local branch missing-branch could not be resolved"

start_case "SHA-256 repositories and deletion sentinels"
CASE_DIR="$SUITE_DIR/case-$CASES"
WORK="$CASE_DIR/work"
REMOTE="$CASE_DIR/remote.git"
OUTPUT="$CASE_DIR/output"
mkdir -p "$CASE_DIR"
"$REAL_GIT" init --bare --object-format=sha256 -q "$REMOTE"
"$REAL_GIT" clone -q "$REMOTE" "$WORK" 2>/dev/null
"$REAL_GIT" -C "$WORK" config user.name "Stack Tests"
"$REAL_GIT" -C "$WORK" config user.email "stack-tests@example.com"
printf 'base\n' > "$WORK/base"
"$REAL_GIT" -C "$WORK" add base
"$REAL_GIT" -C "$WORK" commit -qm base
"$REAL_GIT" -C "$WORK" branch -M master
"$REAL_GIT" -C "$WORK" push -qu origin master
"$REAL_GIT" -C "$WORK" remote set-head origin master
"$REAL_GIT" -C "$WORK" checkout -qb feature-a
commit_file a a A
push_branch feature-a
run_push -y --no-fetch feature-a
check_status 0
check_output "No branches need restacking."
remote_a=$("$REAL_GIT" -C "$WORK" rev-parse origin/feature-a)
zero64=0000000000000000000000000000000000000000000000000000000000000000
run_check "(delete) $zero64 refs/heads/feature-a $remote_a" --no-fetch origin
check_status 0
check_no_output "not an available commit"
check_no_output "could not compare ancestry"

printf '\n%d cases, %d assertions, %d failure(s)\n' \
  "$CASES" "$ASSERTIONS" "$FAILURES"
if [[ $FAILURES -ne 0 ]]; then
  printf 'Test repositories: %s\n' "$SUITE_DIR"
  exit 1
fi
printf 'All stack-tool tests passed.\n'
