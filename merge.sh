#!/bin/bash

# Syncs list of local branches with remote and merges the branches to a target branch
# It does not rebase the branches, it just merges them.
#
# Usage: ./merge.sh [-f] [-n] <target_branch> <source_branch1> [source_branch2] [source_branch3] ...
# Example: ./merge.sh release branch1 branch2
#   -f  Push with --no-verify (skip pre-push hooks)
#   -n  Skip resetting branches to origin (use local state as-is)

set -e

GREEN='\x1B[1;32m'
YELLOW='\x1B[1;33m'
RED='\x1B[1;31m'
LIGHT_WHITE='\x1B[37m'
BOLD_WHITE='\x1B[1;97m'
DEFCOLOR='\x1B[0;m'

NO_VERIFY=false
NO_REBASE=false

while getopts "fn" opt; do
    case $opt in
        f) NO_VERIFY=true ;;
        n) NO_REBASE=true ;;
        *) ;;
    esac
done
shift $((OPTIND - 1))

if [ $# -lt 2 ]; then
    echo "Usage: $0 [-f] [-n] <target_branch> <source_branch1> [source_branch2] [source_branch3] ..."
    echo "Example: $0 release branch1 branch2"
    echo "  -f  Push with --no-verify (skip pre-push hooks)"
    echo "  -n  Skip resetting branches to origin (use local state as-is)"
    exit 1
fi

TARGET_BRANCH=$1
shift
SOURCE_BRANCHES=("$@")

git fetch --all -q

git checkout "$TARGET_BRANCH" -q
if [[ "$NO_REBASE" == false ]]; then
    git reset --hard "origin/$TARGET_BRANCH" -q
fi

# Store the original commit SHA of the target branch
ORIGINAL_SHA=$(git rev-parse "origin/$TARGET_BRANCH")

for BRANCH in "${SOURCE_BRANCHES[@]}"; do
    printf $YELLOW"Merging ${BOLD_WHITE}${BRANCH}${YELLOW} to ${BOLD_WHITE}${TARGET_BRANCH}${DEFCOLOR}\n"
    git checkout "$BRANCH" -q
    if [[ "$NO_REBASE" == false ]]; then
        git reset --hard "origin/$BRANCH" -q
    fi
    git checkout "$TARGET_BRANCH" -q
    
    merge_output=$(git merge "$BRANCH" --no-edit 2>&1)
    merge_return_code=$?
    
    if [[ $merge_output == *"Already up to date."* ]]; then
        printf $YELLOW"${BOLD_WHITE}Branch ${BRANCH} was already merged to ${TARGET_BRANCH} in the past${DEFCOLOR}\n"
        continue
    fi
    
    if [[ $merge_return_code != 0 ]]; then
        if [ -z "$(git rerere remaining)" ]; then
            printf $YELLOW"Auto-accepting past merge conflict resolution${DEFCOLOR}\n"
            conflicted_files=$(git diff --name-only --diff-filter=U)
            git add $conflicted_files
            git commit -q -m "Merge branch '$BRANCH' into $TARGET_BRANCH" --no-edit
            continue
        fi

        printf '\n'$RED'Merging failed!\n'
        printf 'Please choose one of the following options:\n'
        printf '  c) resolve conflicts manually & commit first, and then use this option to continue script\n'
        printf '  s) skip this merge and continue with the next branch\n'
        printf '  or press enter to abort\n'
        read -p "Enter your choice: "

        if [[ $REPLY =~ ^[Cc] ]]; then
            printf $DEFCOLOR
        elif [[ $REPLY =~ ^[Ss] ]]; then
            printf $YELLOW'Skipping the merge for branch '$BRANCH' and continuing...\n'$DEFCOLOR'\n'
            git merge --abort -q
            continue
        else
            git merge --abort -q
            exit $merge_return_code
        fi
    fi
done

# Check if any changes were made by comparing commit SHAs
CURRENT_SHA=$(git rev-parse "$TARGET_BRANCH")

if [[ "$ORIGINAL_SHA" == "$CURRENT_SHA" ]]; then
    printf $YELLOW"No changes made to ${BOLD_WHITE}${TARGET_BRANCH}\n${YELLOW}\n"
else
    printf $GREEN"Pushing to origin/${TARGET_BRANCH}...${DEFCOLOR}\n"
    if [[ "$NO_VERIFY" == true ]]; then
        git push origin "$TARGET_BRANCH" --no-verify
    else
        git push origin "$TARGET_BRANCH"
    fi
fi
