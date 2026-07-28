#!/usr/bin/env bash
#
# Lists remote branches whose tips are older than the configured age and are
# already ancestors of the remote base branch. Deletion is opt-in and uses one
# atomic batches of 50 plus exact leases, so a branch that moves after scanning
# is not deleted.
#
# Examples:
#   prune-merged-branches.sh
#   prune-merged-branches.sh --months=3 --base=main
#   prune-merged-branches.sh --dry-run=false

set -euo pipefail

remote=origin
base=master
months=2
dry_run=true
fetch=true
batch_size=50
protected_branches="dev test release master main"

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --dry-run=true) dry_run=true ;;
    --dry-run=false) dry_run=false ;;
    --remote=*) remote=${arg#*=} ;;
    --base=*) base=${arg#*=} ;;
    --months=*) months=${arg#*=} ;;
    --no-fetch) fetch=false ;;
    -h|--help)
      printf '%s\n' \
        "Usage: prune-merged-branches.sh [options]" \
        "" \
        "Lists old remote branches already merged into the remote base." \
        "Dry-run mode is enabled by default." \
        "" \
        "Options:" \
        "      --dry-run=true|false  preview or perform deletions (default: true)" \
        "      --remote=NAME         remote to inspect (default: origin)" \
        "      --base=BRANCH         merged-branch base (default: master)" \
        "      --months=COUNT        minimum tip age (default: 2)" \
        "      --no-fetch            use existing remote-tracking refs" \
        "  -h, --help                show this help" \
        "" \
        "Protected: dev, test, release, master, main, backup*, and the selected base."
      exit 0
      ;;
    *) fail "unknown option '$arg'; use --help for usage." ;;
  esac
done

[[ -n $remote ]] || fail "--remote requires a non-empty name."
[[ -n $base ]] || fail "--base requires a non-empty name."
[[ $months =~ ^[1-9][0-9]*$ ]] || fail "--months must be a positive integer."
git rev-parse --git-dir >/dev/null 2>&1 ||
  fail "the current directory is not inside a Git repository."
git remote get-url "$remote" >/dev/null 2>&1 ||
  fail "'$remote' is not a configured Git remote."

if [[ $fetch == true ]]; then
  printf 'Fetching branches from %s...\n' "$remote"
  git fetch --quiet --prune "$remote" \
    "+refs/heads/*:refs/remotes/$remote/*" ||
    fail "failed to fetch branches from '$remote'."
else
  printf 'Skipping fetch; using existing branches from %s.\n' "$remote"
fi

base_ref="refs/remotes/$remote/$base"
git show-ref --verify --quiet "$base_ref" ||
  fail "base '$remote/$base' has no remote-tracking ref."
cutoff_arg=$(git rev-parse --since="$months months ago") ||
  fail "could not calculate the age cutoff."
cutoff_epoch=${cutoff_arg#--max-age=}
[[ $cutoff_epoch =~ ^[0-9]+$ ]] ||
  fail "Git returned an invalid age cutoff."

branches=()
shas=()
while IFS=$'\t' read -r commit_epoch commit_date branch sha; do
  [[ -n $branch && $branch != HEAD ]] || continue
  [[ $branch == backup* ]] && continue
  case " $protected_branches $base " in
    *" $branch "*) continue ;;
  esac
  [[ $commit_epoch -lt $cutoff_epoch ]] || continue
  branches+=("$branch")
  shas+=("$sha")
  printf '  %s  %s  %s\n' "$commit_date" "${sha:0:12}" "$branch"
done < <(
  git for-each-ref \
    --merged="$base_ref" \
    --format='%(committerdate:unix)%09%(committerdate:short)%09%(refname:strip=3)%09%(objectname)' \
    "refs/remotes/$remote"
)

if [[ ${#branches[@]} -eq 0 ]]; then
  printf 'No branches older than %s month(s) are merged into %s/%s.\n' \
    "$months" "$remote" "$base"
  exit 0
fi

if [[ $dry_run == true ]]; then
  printf 'Dry run: would delete %d branch(es) from %s. No branches were deleted.\n' \
    "${#branches[@]}" "$remote"
  printf 'Run with --dry-run=false to delete in lease-protected batches of %d.\n' \
    "$batch_size"
  exit 0
fi

printf 'Deleting %d branch(es) from %s in batches of %d...\n' \
  "${#branches[@]}" "$remote" "$batch_size"
failures=()
deleted=0
for ((start = 0; start < ${#branches[@]}; start += batch_size)); do
  end=$((start + batch_size))
  if ((end > ${#branches[@]})); then
    end=${#branches[@]}
  fi
  leases=()
  deletions=()
  for ((i = start; i < end; ++i)); do
    leases+=("--force-with-lease=refs/heads/${branches[i]}:${shas[i]}")
    deletions+=(":refs/heads/${branches[i]}")
  done
  printf '  Deleting batch %d-%d...\n' "$((start + 1))" "$end"
  if git push --atomic --quiet "${leases[@]}" "$remote" "${deletions[@]}"; then
    ((deleted += end - start))
    continue
  fi

  printf '  Warning: batch failed; retrying its branches individually.\n' >&2
  for ((i = start; i < end; ++i)); do
    branch=${branches[i]}
    if git push --quiet \
        "--force-with-lease=refs/heads/$branch:${shas[i]}" \
        "$remote" ":refs/heads/$branch"; then
      ((++deleted))
    else
      printf '  Error: failed to delete %s; continuing.\n' "$branch" >&2
      failures+=("$branch")
    fi
  done
done
if [[ ${#failures[@]} -gt 0 ]]; then
  fail "deleted $deleted branch(es), but failed to delete ${#failures[@]}: ${failures[*]}"
fi
printf 'Deleted %d merged branch(es) from %s.\n' "$deleted" "$remote"
