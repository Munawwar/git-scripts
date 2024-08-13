#!/bin/bash

# install:
# sudo nano /usr/local/bin/rc.sh
# paste & save
# sudo chmod +x /usr/local/bin/rc.sh

# Usage:
# To auto detect branches to merge, use:
# rc.sh --target target-branch -a
# In the above example, the presence of --add/-a or --remove/-r flag indicates auto-detection of branches to be merged.
# Also note, in the example there was no additional branch added even though --add/-a was used.
#
# You can add or remove branches to merge via --add/-a and --remove/-r flags:
# rc.sh --target target-branch [--add branch-1 branch-2 ...] [--remove branch-1 branch-2 ...]
#
# If you dont want to auto-detection branches do not use --add,-a,--remove or -r,
# and then only the branches you specify will be merged:
# rc.sh --target target-branch branch-1 branch-2 ...
#
# To not rebase branches use --no-rebase / -n flag:
# rc.sh --no-rebase --target target-branch branch-1 branch-2 ...
#
# To skips tests (pre-push git hooks) use --no-verify / -f flag:
# rc.sh --no-verify --target target-branch branch-1 branch-2 ...
#
# To train rerere from another branch --rerere-from flag:
# rc.sh --rerere-from test --target release branch-1 branch-2 ...
#
# To skips rerere training use --no-rerere-train flag:
# rc.sh --no-rerere-train --target target-branch branch-1 branch-2 ...
#
# To overwrite rerere memory use --rerere-overwrite flag:
# rc.sh --rerere-overwrite --target target-branch branch-1 branch-2 ...


GREEN='\x1B[1;32m'
YELLOW='\x1B[1;33m'
RED='\x1B[1;31m'
DEFCOLOR='\x1B[0;m'

# Check for unstaged or staged changes
if ! git diff-index --quiet HEAD --; then
  echo -e "${RED}Error: There are unstaged or staged changes in your working directory.${DEFCOLOR}"
  echo "Please commit or stash your changes before running this script."
  exit 1
fi

rebase=1
force=0
rerere_train=1
rerere_overwrite=0
rerere_from_branch=""
mode="manual"
additional_branches=()
remove_branches=()

# Move command-line arguments into an array variable
args=("$@")
args2=()

# Preprocess the args array to remove middle '=' sign (e.g. --target=main)
for arg in "${args[@]}"
do
  if [[ "${arg}" == *=* ]]; then
    echo
    key="${arg%%=*}"   # Extract the part before the equal sign
    value="${arg#*=}"  # Extract the part after the equal sign
    args2+=("$key")
    args2+=("$value")
  else
    args2+=("$arg")
  fi
done
# Replace args to be without = sign
args=("${args2[@]}")

# Preprocess the args array to split flags from non-flag arguments
for ((i=0; i<${#args[@]}; i+=1))
do
  arg="${args[i]}"

  case ${args[i]} in
    -t|--target)
      value=""
      if [[ "$arg" == *=* ]]; then
        # Split the flag from its value
        value="${arg#*=}"  # Extract the part after the equal sign
      elif [[ "${args[i+1]}" != -* ]]; then
        value=("${args[i+1]}")
        ((i++))
      else
        printf '\n'$RED'Please specify a valid branch name for --target / -t flag'$DEFCOLOR'\n'
        exit 1;
      fi
      targetBranch=$value
      ;;
    -a|--add)
      mode="add"
      ;;
    -r|--remove)
      mode="remove"
      ;;
    -f|--no-verify)
      force=1
      ;;
    -n|--no-rebase)
      rebase=0
      ;;
    --no-rerere-train)
      rerere_train=0
      ;;
    --rerere-from)
      value=""
      if [[ "${args[i+1]}" != -* ]]; then
        value=("${args[i+1]}")
        ((i++))
      else
        printf '\n'$RED'Please specify a valid branch name for --rerere-from flag'$DEFCOLOR'\n'
        exit 1;
      fi
      rerere_from_branch=$value
      ;;
    --rerere-overwrite)
      rerere_overwrite=1
      ;;
    -h|--help)
      echo "rc.sh [--no-rebase/-n --no-verify/-f --no-rerere-train --rerere-overwrite] --target/-t target-branch branch-1 branch-2 ..."
      exit
      ;;
    *)
      # ignore any other flag, but detect branch names
      if [[ "$arg" != -* ]]; then
        if [ "$mode" == "manual" ]; then
          branches+=("$arg")
        fi
        if [ "$mode" == "add" ]; then
          additional_branches+=("$arg")
        fi
        if [ "$mode" == "remove" ]; then
          remove_branches+=("$arg")
        fi
      fi
      ;;
  esac
done

if [[ -z $targetBranch ]]; then
  printf '\n'$RED'Please specify target branch via --target or -t argument'$DEFCOLOR'\n'
  exit 1;
fi

printf '\n'$YELLOW'Fetching latest changes from origin'$DEFCOLOR'\n'
git fetch origin

# If no branches were specified auto-detect branches using logic from merges.sh
if [ ${#branches[@]} -eq 0 ] && ([ "$mode" == "add" ] || [ "$mode" == "remove" ]); then
  branches=($(
    git log --format="%s" --merges --reverse origin/master..origin/$targetBranch | \
    sed -E "s~Merge branch '([-\.a-zA-Z0-9]+)' into .+~\1~" | \
    sed -E "s~Merge pull request #[0-9]+ from Carriyo/(.+)~\1~" | \
    awk '!x[$0]++'
  ))
fi

# Add additional branches
if [ ${#additional_branches[@]} -gt 0 ]; then
  branches+=("${additional_branches[@]}")
  # De-duplicate branches while preserving order
  readarray -t branches < <(printf '%s\n' "${branches[@]}" | awk '!seen[$0]++')
fi

# Remove specified branches
if [ ${#remove_branches[@]} -gt 0 ]; then
  new_branches=()
  for branch in "${branches[@]}"; do
    if [[ ! " ${remove_branches[@]} " =~ " ${branch} " ]]; then
      new_branches+=("$branch")
    fi
  done
  branches=("${new_branches[@]}")
fi

if [[ -z $rerere_from_branch ]]; then
  rerere_from_branch=$targetBranch
fi

printf '\ntarget: '$targetBranch'\n'
printf "rebase: $(if ((rebase)); then echo true; else echo false; fi)\n"
printf "verify: $(if ((force)); then echo false; else echo true; fi)\n"
printf "rerere train: $(if ((rerere_train)); then echo true; else echo false; fi)\n"
if [[ $rerere_train == 1 ]]; then
  printf "rerere train overwrite: $(if ((rerere_overwrite)); then echo true; else echo false; fi)\n"
  printf "rerere train from branch: ${rerere_from_branch:-$targetBranch}\n"
fi
printf "\nbranches: ${branches[*]}\n\n"

# if two branches with same name but different cases are present, then it causes problems when checking out..
# so delete local branch so that script works correctly
#git branch | grep -Po '.*\w{1,}\-\d{1,}' | xargs git branch -D

git checkout -q master
if [ $? -ne 0 ]; then
  printf $RED'Error: Failed to switch to master branch.'$DEFCOLOR'\n'
  exit 1
fi
git reset -q --hard origin/master

# Rerere train on commits between master and target branch
# so that past merge conflict resolutions are reused
if [[ $rerere_train == 1 ]]; then
  printf $RED
  # we need the GIT_DIR env to be set
  . "$(git --exec-path)/git-sh-setup"
  printf $DEFCOLOR
  # make sure we are in the same directory as the git directory
  cd_to_toplevel
  mkdir -p "$GIT_DIR/rr-cache" || exit 1

  train_rerere() {
    local rerere_from_branch=$1

    printf $YELLOW"Rerere training on commits from master to $rerere_from_branch ..."$DEFCOLOR'\n'

    git rev-list --parents master..origin/$rerere_from_branch |
    while read commit parent1 other_parents
    do
      if test -z "$other_parents"
      then
        # Skip non-merges
        continue
      fi
      git checkout -q "$parent1^0"
      if [ $? -ne 0 ]; then
        printf $RED'Error: Failed to switch to '$parent1'^0 commit.'$DEFCOLOR'\n'
        exit 1
      fi
      if git merge --no-gpg-sign $other_parents >/dev/null 2>&1
      then
        # Cleanly merges
        continue
      fi
      if test $rerere_overwrite = 1
      then
        git rerere forget .
      fi
      if test -s "$GIT_DIR/MERGE_RR"
      then
        git --no-pager show -s --format="Learning from %h %s" "$commit"
        git rerere
        git checkout -q $commit -- .
        git rerere
      fi
      git reset -q --hard  # Might nuke untracked files...
    done
  }

  # First, train on rerere_from_branch
  train_rerere "$rerere_from_branch"

  # Then, if targetBranch is different, train on it as well
  if [ "$targetBranch" != "$rerere_from_branch" ]; then
    train_rerere "$targetBranch"
  fi

  git checkout -q master
  printf $YELLOW'Rerere training done'$DEFCOLOR'\n\n'
fi

# checkout all branches to sync with remote
unmerged_branches=()
for i in "${branches[@]}"; do
  # .. sync with remote
  git checkout -q $i
  if [ $? -ne 0 ]; then
    printf $RED'Error: Failed to switch to '$i' branch.'$DEFCOLOR'\n'
    exit 1
  fi
  git reset -q --hard origin/$i

  # first check if branch was already merged to master or not
  common_ancestor=$(git merge-base master $i)
  current_branch_commit_hash=$(git rev-parse $i)
  if [[ $common_ancestor == $current_branch_commit_hash ]]; then
    printf $YELLOW''$i' was already merged to master'$DEFCOLOR'\n'
  else
    unmerged_branches+=("$i")
  fi
done

if [[ $rebase -eq 1 ]]; then
  # Function to check if a branch is on top of another branch
  printf $YELLOW"Checking for stacked branches ..."$DEFCOLOR'\n'

  # If there are stacked branches, exclude duplicate branches for rebasing, by picking the top-most branches
  is_on_top_of() {
    git branch --contains $1 --format='%(refname:short)' | grep -qx $2
  }

  base_branches=()
  for ((i=0; i<${#unmerged_branches[@]}; i++)); do
    for ((j=0; j<${#unmerged_branches[@]}; j++)); do
      # printf "Checking branch ${unmerged_branches[i]} against ${unmerged_branches[j]}\n"
      if [[ ${unmerged_branches[i]} != ${unmerged_branches[j]} ]]; then
        if is_on_top_of ${unmerged_branches[j]} ${unmerged_branches[i]}; then
          printf $YELLOW"Branch ${unmerged_branches[i]} is on top of branch ${unmerged_branches[j]}"$DEFCOLOR'\n'
          base_branches+=(${unmerged_branches[j]})
          break
        fi
      fi
    done
  done

  # Find the top-most branches (branches that are not in the base_branches array)
  top_branches=()
  for branch in "${unmerged_branches[@]}"; do
    if [[ ! " ${base_branches[@]} " =~ " $branch " ]]; then
      top_branches+=($branch)
    fi
  done

  printf '\n'

  handle_rebase_failure() {
    local branch=$1
    while true; do
      printf "${RED}Rebasing $branch to master failed. Choose an option:\n"
      if [ -z "$(git rerere remaining)" ]; then
        printf "  a) Stage resolved changes and continue rebase\n"
      fi
      printf "  s) Skip this branch and continue with the rest\n"
      printf "  or press enter to abort\n"
      read -p "Enter your choice: " choice
      printf $DEFCOLOR

      if [[ $choice =~ ^[Aa] ]]; then
        if [ -z "$(git rerere remaining)" ]; then
          echo "Staging changes and continuing rebase."
          conflicted_files=$(git diff --name-only --diff-filter=U)
          echo "Conflicted files: $conflicted_files"
          git add $conflicted_files
          # GIT_EDITOR=true skips asking for a commit message
          GIT_EDITOR=true git rebase --continue
          if [ $? -eq 0 ]; then
            # successful rebase
            return 0
          else
            continue  # This will repeat the loop
          fi
        else
          git rebase --abort 1> /dev/null
          exit 1
        fi
      elif [[ $choice =~ ^[Ss] ]]; then
        git rebase --abort 1> /dev/null
        return 1
      else
        git rebase --abort 1> /dev/null
        exit 1
      fi
    done
  }

  # rebase all top branches to master
  for i in "${top_branches[@]}"; do
    git checkout -q $i
    printf $YELLOW'Rebasing '$i' to master'$DEFCOLOR'\n'
    # .. and then rebase to master
    git rebase --update-refs master 1> /dev/null
    if [[ $? != 0 ]] && ! handle_rebase_failure $i; then
      printf $RED"Removing $i from unmerged_branches due to rebase failure"$DEFCOLOR'\n'
      new_branches=()
      for branch in "${unmerged_branches[@]}"; do
        if [[ ! " ${i} " =~ " ${branch} " ]]; then
          new_branches+=("$branch")
        fi
      done
      unmerged_branches=("${new_branches[@]}")
      echo "Unmerged branches: ${unmerged_branches[*]}"
    fi
    # sleep required to give git time to unlock rebase/merge locks
    sleep 2
  done
fi

# merge everything to target-branch
echo ''
git checkout -q $targetBranch
if [ $? -ne 0 ]; then
  printf $RED'Error: Failed to switch to '$targetBranch' branch.'$DEFCOLOR'\n'
  exit 1
fi
git reset -q --hard origin/master
sleep 2

for i in "${unmerged_branches[@]}"; do
  printf $YELLOW"Merging $i to $targetBranch"$DEFCOLOR'\n'
  git merge --no-ff --no-edit $i 1> /dev/null
  merge_return_code=$?
  if [[ $merge_return_code != 0 ]]; then
    remaining_conflicts=$(git rerere remaining | wc -l)

    printf '\n'$RED'Merging failed!\n'
    printf 'Please choose one of the following options:\n'
    if [[ $remaining_conflicts -eq 0 ]]; then
      printf '  a) accept current merge conflict resolution\n'
    fi
    printf '  c) resolve conflicts manually & commit first, and then use this option to continue script\n'
    printf '  s) skip this merge and continue with the next branch\n'
    printf '  or press enter to abort\n'
    read -p "Enter your choice: "

    if [[ $REPLY =~ ^[Cc] ]]; then
      printf $DEFCOLOR
    elif [[ $REPLY =~ ^[Ss] ]]; then
      printf $YELLOW'Skipping the merge for branch '$i' and continuing...\n'$DEFCOLOR'\n'
      git merge --abort 1> /dev/null
      continue
    elif [[ $REPLY =~ ^[Aa] && $remaining_conflicts -eq 0 ]]; then
      printf $YELLOW'Accepting current merge conflict resolution and committing changes...\n'$DEFCOLOR'\n'
      git add . 1> /dev/null
      git commit -q -m "Merge branch '$i' into $targetBranch" --no-edit
    else
      git merge --abort 1> /dev/null
      exit $merge_return_code;
    fi
  fi
  sleep 2
done

echo ''
printf $GREEN'-----------\n'
printf 'Change log\n'
printf $GREEN'-----------\n'
git log --format="%s (%an)" --no-merges master..$targetBranch | cat -
printf $DEFCOLOR'\n'

printf $YELLOW
read -p "Force push local branchs. Proceed? (y/n) " -r
printf $DEFCOLOR
if [[ $REPLY =~ ^[Yy]$ ]]; then
  if [[ $force == 1 ]]; then
    git push --force-with-lease --no-verify origin "${unmerged_branches[@]}" "$targetBranch"
  fi
  if [[ $force == 0 ]]; then
    git push --force-with-lease origin "${unmerged_branches[@]}" "$targetBranch"
  fi
fi
