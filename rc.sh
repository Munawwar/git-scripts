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
# If you don't want to auto-detection branches do not use --add,-a,--remove or -r,
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
LIGHT_WHITE='\x1B[37m'
BOLD_WHITE='\x1B[1;97m'
DEFCOLOR='\x1B[0;m'

# Check for unstaged or staged changes
if ! git diff-index --quiet HEAD --; then
  echo -e "${RED}Error: There are unstaged or staged changes in your working directory.${DEFCOLOR}"
  echo "Please commit or stash your changes before running this script."
  exit 1
fi

base=master
rebase=1
force=0
rerere_train=1
rerere_overwrite=0
rerere_from_branch=""
mode="manual"
additional_branches=()
remove_branches=()
auto_approve=0

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
    --base)
      value=""
      if [[ "$arg" == *=* ]]; then
        # Split the flag from its value
        value="${arg#*=}"  # Extract the part after the equal sign
      elif [[ "${args[i+1]}" != -* ]]; then
        value=("${args[i+1]}")
        ((i++))
      else
        value="master"
      fi
      base=$value
      ;;
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
    -y|--approve)
      auto_approve=1
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
    git log --format="%s" --merges --reverse origin/$base..origin/$targetBranch | \
    sed -E "s~Merge branch '([^/]+)' into .+~\1~" | \
    sed -E "s~Merge (remote-tracking )?branch '.+/(.+)' into .+~\2~" | \
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

printf "\n${BOLD_WHITE}target branch:${DEFCOLOR} ${GREEN}$targetBranch${DEFCOLOR}\n"
printf "${BOLD_WHITE}base branch:${DEFCOLOR} ${GREEN}$base${DEFCOLOR}\n"
printf "${BOLD_WHITE}rebase branches?${DEFCOLOR} $(if ((rebase)); then echo "yes"; else echo "no"; fi)\n"
printf "${BOLD_WHITE}verify before push?${DEFCOLOR} $(if ((force)); then echo "no"; else echo "yes"; fi)\n"
printf "${BOLD_WHITE}rerere train?${DEFCOLOR} $(if ((rerere_train)); then echo "yes"; else echo "no"; fi)\n"
if [[ $rerere_train == 1 ]]; then
  printf "${BOLD_WHITE}rerere train overwrite?${DEFCOLOR} $(if ((rerere_overwrite)); then echo "yes"; else echo "no"; fi)\n"
  printf "${BOLD_WHITE}rerere train from branch: ${rerere_from_branch:-$targetBranch}${DEFCOLOR}\n"
fi
printf "\n${BOLD_WHITE}branches:${DEFCOLOR}\n"
for branch in "${branches[@]}"; do
    printf "${GREEN}${branch}${DEFCOLOR}\n"
done
printf "\n"

# if two branches with same name but different cases are present, then it causes problems when checking out..
# so delete local branch so that script works correctly
#git branch | grep -Po '.*\w{1,}\-\d{1,}' | xargs git branch -D

git checkout -q $base
if [ $? -ne 0 ]; then
  printf $RED'Error: Failed to switch to '$base' branch.'$DEFCOLOR'\n'
  exit 1
fi
git reset -q --hard origin/$base

# Rerere train on commits between $base and target branch
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

    printf $YELLOW"Rerere training on commits from "$base" to "$rerere_from_branch" ..."$DEFCOLOR"\n"

    git rev-list --parents $base..origin/$rerere_from_branch |
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

  git checkout -q $base
  printf $YELLOW'Rerere training done'$DEFCOLOR'\n\n'
fi

# checkout all branches to sync with remote
unmerged_branches=()
merged_branches=()
for i in "${branches[@]}"; do
  # .. sync with remote
  git checkout -q $i
  if [ $? -ne 0 ]; then
    printf $RED'Error: Failed to switch to '$i' branch.'$DEFCOLOR'\n'
    exit 1
  fi
  git reset -q --hard origin/$i

  # first check if branch was already merged to $base or not
  common_ancestor=$(git merge-base $base $i)
  current_branch_commit_hash=$(git rev-parse $i)
  if [[ $common_ancestor == $current_branch_commit_hash ]]; then
    merged_branches+=("$i")
  else
    unmerged_branches+=("$i")
  fi
done

# Print already merged branches under one header
if [ ${#merged_branches[@]} -gt 0 ]; then
  printf "${YELLOW}Skipping branches already merged to ${base}:${DEFCOLOR}\n"
  for branch in "${merged_branches[@]}"; do
    printf "${BOLD_WHITE}${branch}${DEFCOLOR}\n"
  done
  printf "\n"
fi

if [[ $rebase -eq 1 ]]; then
  printf $YELLOW"Analyzing branch dependencies ..."$DEFCOLOR"\n"

  # Initialize arrays for branch dependencies and their distance from base
  declare -A branch_deps          # Stores direct dependencies
  declare -A branch_base_distance # Stores distance to base branch

  # For each branch, find the closest dependency and its distance from base
  for branch in "${unmerged_branches[@]}"; do
    # Find distance to base
    base_common_ancestor=$(git merge-base $base $branch)
    base_distance=$(git rev-list --count $base_common_ancestor..$branch)
    branch_base_distance[$branch]=$base_distance
    
    # Find direct dependency branch by picking the dependency branch that
    # is the closest to it in number of commits
    # e.g. if A -> B (2 commits) -> C (1 commit), then C is 3 commits away
    # from A and 1 commit away from B, so C's direct dependency is B.
    closest_dependency=""
    min_distance=999999
    
    for other_branch in "${unmerged_branches[@]}"; do
      if [[ "$branch" != "$other_branch" ]]; then
        # Get common ancestor
        merge_base=$(git merge-base $branch $other_branch)
        
        # If other_branch is an ancestor of branch
        if [[ "$(git rev-parse $other_branch)" == "$(git rev-parse $merge_base)" ]]; then
          # Check distance
          distance=$(git rev-list --count $other_branch..$branch)
          if [[ $distance -gt 0 && $distance -lt $min_distance ]]; then
            closest_dependency=$other_branch
            min_distance=$distance
          fi
        fi
      fi
    done
    
    branch_deps[$branch]=$closest_dependency
  done

  # Sort branches by their distance from base
  sorted_branches=($(
    for branch in "${unmerged_branches[@]}"; do
      echo "${branch_base_distance[$branch]} $branch"
    done | sort -n | cut -d' ' -f2
  ))

  # Print branch dependencies
  has_dependencies=0
  for branch in "${sorted_branches[@]}"; do
    depends_on="${branch_deps[$branch]:-$base}"
    if [[ "$depends_on" != "$base" ]]; then
      printf "${BOLD_WHITE}${branch}${DEFCOLOR} ${LIGHT_WHITE}depends on${DEFCOLOR} ${BOLD_WHITE}${depends_on}${DEFCOLOR}\n"
      has_dependencies=1
    fi
  done
  if [[ $has_dependencies -eq 0 ]]; then
    printf "No inter-branch dependencies found (all branches depend directly on ${base})\n"
  fi
  printf $YELLOW"Analyzing branch dependencies done"$DEFCOLOR'\n\n'

  handle_rebase_failure() {
    local branch=$1
    while true; do
      if [ -z "$(git rerere remaining)" ]; then
        printf $YELLOW"Auto-accepting past merge conflict resolution"$DEFCOLOR"\n"
        conflicted_files=$(git diff --name-only --diff-filter=U)
        #echo "Conflicted files: $conflicted_files"
        git add $conflicted_files
        # GIT_EDITOR=true skips asking for a commit message
        GIT_EDITOR=true git rebase --continue
        if [ $? -eq 0 ]; then
          # successful rebase
          return 0
        else
          continue  # This will repeat the loop
        fi
      fi
      printf "${RED}Rebasing ${GREEN}$branch${RED} to ${GREEN}$base${RED} failed. Choose an option:\n"
      printf "  s) Skip this branch and continue with the rest\n"
      printf "  or press enter to abort\n"
      read -p "Enter your choice: " choice
      printf $DEFCOLOR

      if [[ $choice =~ ^[Ss] ]]; then
        git rebase --abort 1> /dev/null
        return 1
      else
        git rebase --abort 1> /dev/null
        exit 1
      fi
    done
  }

  # Rebase branches in order
  for branch in "${sorted_branches[@]}"; do
    depends_on="${branch_deps[$branch]:-$base}"
    printf "${YELLOW}Rebasing ${BOLD_WHITE}${branch}${YELLOW} to ${depends_on} ..."$DEFCOLOR"\n"
    git checkout -q $branch
    git rebase --update-refs $depends_on 1> /dev/null

    if [[ $? != 0 ]] && ! handle_rebase_failure $branch; then
      printf $RED"Removing $branch from unmerged_branches due to rebase failure"$DEFCOLOR'\n'
      new_branches=()
      for b in "${unmerged_branches[@]}"; do
        if [[ ! " ${branch} " =~ " ${b} " ]]; then
          new_branches+=("$b")
        fi
      done
      unmerged_branches=("${new_branches[@]}")
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
git reset -q --hard origin/$base
sleep 2

for i in "${unmerged_branches[@]}"; do
  printf $YELLOW"Merging ${BOLD_WHITE}${i}${YELLOW} to ${targetBranch} ..."$DEFCOLOR'\n'
  git merge --no-ff --no-edit $i 1> /dev/null
  merge_return_code=$?
  if [[ $merge_return_code != 0 ]]; then
    if [ -z "$(git rerere remaining)" ]; then
      printf $YELLOW"Auto-accepting past merge conflict resolution"$DEFCOLOR"\n"
      conflicted_files=$(git diff --name-only --diff-filter=U)
      #echo "Conflicted files: $conflicted_files"
      git add $conflicted_files
      git commit -q -m "Merge branch '$i' into $targetBranch" --no-edit
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
      printf $YELLOW'Skipping the merge for branch '$i' and continuing...\n'$DEFCOLOR'\n'
      git merge --abort 1> /dev/null
      continue
    else
      git merge --abort 1> /dev/null
      exit $merge_return_code;
    fi
  fi
  sleep 2
done

printf "\n"$BOLD_WHITE"-----------"$DEFCOLOR"\n"
printf $BOLD_WHITE"Change log"$DEFCOLOR
printf "\n"$BOLD_WHITE"-----------"$DEFCOLOR"\n"
git log --format="- %s (%an)" --no-merges $base..$targetBranch | cat -
printf "\n"

printf $YELLOW
if [[ $auto_approve == 0 ]]; then
  read -p "Force push local branches. Proceed? (y/n) " -r
  printf $DEFCOLOR
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
  fi
else
  printf 'Force pushing local branches'$DEFCOLOR'\n'
fi

# Fetch again just in case new changes were pushed by the time we reach here
git fetch origin
# Common push logic
if [[ $force == 1 ]]; then
  git push --force-with-lease --no-verify origin "${unmerged_branches[@]}" "$targetBranch"
else
  git push --force-with-lease origin "${unmerged_branches[@]}" "$targetBranch"
fi
