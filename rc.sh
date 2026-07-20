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

warn() {
  printf "${YELLOW}Warning:${DEFCOLOR} %s\n" "$1"
}

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
recent_remote_months=2

array_contains_exact() {
  local needle=$1
  shift
  local item
  for item in "$@"; do
    [[ $item == "$needle" ]] && return 0
  done
  return 1
}

filter_branch_out() {
  local needle=$1
  shift
  local item
  for item in "$@"; do
    [[ $item == "$needle" ]] || printf '%s\n' "$item"
  done
}

sort_branches_by_distance() {
  local branch
  for branch in "$@"; do
    printf '%s %s\n' "$(map_get "$branch_base_distance" "$branch" || printf '0')" "$branch"
  done | sort -n | cut -d' ' -f2
}

map_get() {
  local records=$1
  local needle=$2
  local key value
  while IFS=$'\t' read -r key value; do
    [[ -n $key ]] || continue
    if [[ $key == "$needle" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done <<EOF
$records
EOF
  return 1
}

map_set() {
  local var_name=$1
  local needle=$2
  local replacement=$3
  local current_records=${!var_name}
  local new_records=""
  local key value
  local found=0

  while IFS=$'\t' read -r key value; do
    [[ -n $key ]] || continue
    if [[ $key == "$needle" ]]; then
      value=$replacement
      found=1
    fi
    if [[ -n $new_records ]]; then
      new_records+=$'\n'
    fi
    new_records+="${key}"$'\t'"${value}"
  done <<EOF
$current_records
EOF

  if [[ $found -eq 0 ]]; then
    if [[ -n $new_records ]]; then
      new_records+=$'\n'
    fi
    new_records+="${needle}"$'\t'"${replacement}"
  fi

  printf -v "$var_name" '%s' "$new_records"
}

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

if ! git show-ref --verify --quiet "refs/remotes/origin/$base"; then
  printf "${RED}Error: base branch ${BOLD_WHITE}%s${RED} has no origin branch. Fix the base or push origin/%s first.${DEFCOLOR}\n" "$base" "$base"
  exit 1
fi

# If no branches were specified, infer the already-merged branch list from the
# target branch history. Keep this in sync with list-merges.sh.
if [ ${#branches[@]} -eq 0 ] && ([ "$mode" == "add" ] || [ "$mode" == "remove" ]); then
  branches=($(
    git log --format="%s" --merges --reverse "origin/$base..origin/$targetBranch" | \
    sed -E \
      -e "s~^Merge remote-tracking branch '((refs/)?remotes/)?[^/]+/([^']+)'.*~\3~" \
      -e "s~^Merge remote-tracking branch '([^']+)'.*~\1~" \
      -e "s~^Merge branch '([^']+)'.*~\1~" \
      -e "s~^Merge pull request #[0-9]+ from [^/]+/(.+)~\1~" | \
    awk '!x[$0]++'
  ))
fi

# Add additional branches
if [ ${#additional_branches[@]} -gt 0 ]; then
  branches+=("${additional_branches[@]}")
  # De-duplicate branches while preserving order
  deduped_branches=()
  while IFS= read -r branch; do
    deduped_branches+=("$branch")
  done < <(printf '%s\n' "${branches[@]}" | awk '!seen[$0]++')
  branches=("${deduped_branches[@]}")
fi

# Remove specified branches
if [ ${#remove_branches[@]} -gt 0 ]; then
  new_branches=()
  for branch in "${branches[@]}"; do
    if ! array_contains_exact "$branch" "${remove_branches[@]}"; then
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
  if ! git show-ref --verify --quiet "refs/remotes/origin/$i"; then
    printf "${RED}Error: branch ${BOLD_WHITE}%s${RED} has no origin branch. Push it first and then rerun rc.sh.${DEFCOLOR}\n" "$i"
    exit 1
  fi
  # .. sync with remote
  git checkout -q $i
  if [ $? -ne 0 ]; then
    printf $RED'Error: Failed to switch to '$i' branch.'$DEFCOLOR'\n'
    exit 1
  fi
  git reset -q --hard origin/$i

  # first check if branch was already merged to $base or not
  common_ancestor=$(git merge-base "$base" "$i")
  current_branch_commit_hash=$(git rev-parse "$i")
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

branches_to_push=("${unmerged_branches[@]}")
sorted_merge_branches=("${unmerged_branches[@]}")

if [[ $rebase -eq 1 ]]; then
  printf $YELLOW"Analyzing branch dependencies ..."$DEFCOLOR"\n"

  branch_deps=""          # Direct inferred dependency for each branch
  branch_base_distance="" # Distance from the base branch used for sorting
  remote_ref_map=""       # origin ref for each branch
  branch_point_map=""     # Branch point from base for each branch
  child_map=""            # Space-separated inferred children for each branch
  recent_remote_branches=()       # Recently active remote branches plus requested merge branches
  graph_branches=()               # Ordered widened branch cohort used for dependency inference
  impacted_only_branches=()       # Newly detected descendants outside the requested merge list
  release_branches=(dev test release master main)
  cutoff_arg=$(git rev-parse --since="${recent_remote_months} months ago")
  cutoff_epoch=${cutoff_arg#--max-age=}
  base_ref="origin/$base"

  # Ideally we would infer stack dependencies from all remote branches, but that
  # gets expensive. So we limit the wider search to remote branches active in the
  # last ${recent_remote_months} months.
  while IFS=' ' read -r commit_epoch branch; do
    [[ $branch == "HEAD" ]] && continue
    if array_contains_exact "$branch" "${release_branches[@]}"; then
      continue
    fi
    # Branches already merged into the base branch are already on prod and do
    # not need to participate in stack inference.
    if git merge-base --is-ancestor "origin/$branch" "$base_ref"; then
      continue
    fi
    if [[ $commit_epoch -ge $cutoff_epoch ]]; then
      recent_remote_branches+=("$branch")
    fi
  done < <(git for-each-ref --format='%(committerdate:unix) %(refname:strip=3)' refs/remotes/origin)

  # Force-include explicitly requested merge branches even if they are older
  # than the recent-activity cutoff.
  for branch in "${unmerged_branches[@]}"; do
    if ! array_contains_exact "$branch" "${recent_remote_branches[@]}"; then
      recent_remote_branches+=("$branch")
    fi
  done

  for branch in "${unmerged_branches[@]}"; do
    graph_branches+=("$branch")
  done

  # Build remote-only metadata for the recent origin branch set plus any explicitly
  # requested merge branches, even if they are older than the recent-activity cutoff.
  for branch in "${recent_remote_branches[@]}"; do
    if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      map_set remote_ref_map "$branch" "origin/$branch"
      map_set branch_point_map "$branch" "$(git merge-base "$base_ref" "origin/$branch")"
    else
      map_set remote_ref_map "$branch" ""
      map_set branch_point_map "$branch" ""
    fi
    map_set child_map "$branch" ""
  done

  # For each requested merge branch, collect other recent remote branches that
  # forked from base at the same commit. This gives us a candidate branch family
  # that may belong to the same stack. Actual parent/child relationships are
  # inferred in the next block.
  for branch in "${unmerged_branches[@]}"; do
    branch_point=$(map_get "$branch_point_map" "$branch" || true)
    if [[ -z $branch_point ]]; then
      warn "Could not determine the branch point of ${branch} from origin/${base}; skipping wider stack detection for this branch."
      continue
    fi
    for other_branch in "${recent_remote_branches[@]}"; do
      [[ "$other_branch" == "$branch" ]] && continue
      other_branch_point=$(map_get "$branch_point_map" "$other_branch" || true)
      [[ $other_branch_point == "$branch_point" ]] || continue
      if ! array_contains_exact "$other_branch" "${release_branches[@]}" && ! array_contains_exact "$other_branch" "${graph_branches[@]}"; then
        graph_branches+=("$other_branch")
      fi
    done
  done

  # Inside the wider cohort, infer the direct parent of each branch by choosing
  # the nearest ancestor branch on origin.
  valid_graph_branches=()
  for branch in "${graph_branches[@]}"; do
    subject_ref=$(map_get "$remote_ref_map" "$branch" || true)
    if [[ -z $subject_ref ]]; then
      warn "Skipping ${branch} during stack inference because origin/${branch} could not be resolved."
      continue
    fi
    valid_graph_branches+=("$branch")
  done

  for branch in "${valid_graph_branches[@]}"; do
    subject_ref=$(map_get "$remote_ref_map" "$branch" || true)
    closest_dependency=""
    min_distance=999999
    for other_branch in "${valid_graph_branches[@]}"; do
      [[ "$branch" == "$other_branch" ]] && continue
      candidate_ref=$(map_get "$remote_ref_map" "$other_branch" || true)
      # Check if candidate_ref is an ancestor of subject_ref.
      if git merge-base --is-ancestor "$candidate_ref" "$subject_ref"; then
        distance=$(git rev-list --count "$candidate_ref..$subject_ref")
        if [[ $distance -gt 0 && $distance -lt $min_distance ]]; then
          closest_dependency=$other_branch
          min_distance=$distance
        fi
      fi
    done

    map_set branch_deps "$branch" "$closest_dependency"
    if [[ -n $closest_dependency ]]; then
      existing_children=$(map_get "$child_map" "$closest_dependency" || true)
      if [[ -n $existing_children ]]; then
        existing_children="$existing_children $branch"
      else
        existing_children=$branch
      fi
      map_set child_map "$closest_dependency" "$existing_children"
    fi

    base_common_ancestor=$(git merge-base "$base_ref" "$subject_ref")
    map_set branch_base_distance "$branch" "$(git rev-list --count "$base_common_ancestor..$subject_ref")"
  done

  # What we have so far is the stack graph for the all (actually recent) remote branches.
  # We need to next figure out which of those are relevant for our target-branch creation.
  # Starting from the requested merge branches, walk downward through that graph to keep
  # only the relevant descendants
  for branch in "${unmerged_branches[@]}"; do
    pending=($(map_get "$child_map" "$branch" || true))
    while [[ ${#pending[@]} -gt 0 ]]; do
      current_branch=${pending[0]}
      pending=("${pending[@]:1}")
      current_branch_ref=$(map_get "$remote_ref_map" "$current_branch" || true)
      if [[ -z $current_branch_ref ]]; then
        warn "Skipping descendant ${current_branch} because origin/${current_branch} could not be resolved."
        continue
      fi
      common_ancestor=$(git merge-base "$base" "$current_branch_ref")
      current_branch_commit_hash=$(git rev-parse "$current_branch_ref")
      if [[ $common_ancestor != $current_branch_commit_hash ]] && ! array_contains_exact "$current_branch" "${branches_to_push[@]}"; then
        branches_to_push+=("$current_branch")
        impacted_only_branches+=("$current_branch")
      fi
      for child_branch in $(map_get "$child_map" "$current_branch" || true); do
        pending+=("$child_branch")
      done
    done
  done

  sorted_branches=($(sort_branches_by_distance "${branches_to_push[@]}"))
  sorted_merge_branches=($(sort_branches_by_distance "${unmerged_branches[@]}"))

  # Print branch dependencies
  has_dependencies=0
  for branch in "${sorted_branches[@]}"; do
    depends_on=$(map_get "$branch_deps" "$branch" || true)
    [[ -n $depends_on ]] || depends_on=$base
    if [[ "$depends_on" != "$base" ]]; then
      printf "${BOLD_WHITE}${branch}${DEFCOLOR} ${LIGHT_WHITE}depends on${DEFCOLOR} ${BOLD_WHITE}${depends_on}${DEFCOLOR}\n"
      has_dependencies=1
    fi
  done
  if [[ $has_dependencies -eq 0 ]]; then
    printf "No inter-branch dependencies found (all branches depend directly on ${base})\n"
  fi
  if [[ ${#impacted_only_branches[@]} -gt 0 ]]; then
    printf "\n${YELLOW}Also rebasing and force-pushing impacted stacked branches outside the merge list:${DEFCOLOR}\n"
    for branch in "${impacted_only_branches[@]}"; do
      depends_on=$(map_get "$branch_deps" "$branch" || true)
      [[ -n $depends_on ]] || depends_on=$base
      printf "${BOLD_WHITE}${branch}${DEFCOLOR} ${LIGHT_WHITE}depends on${DEFCOLOR} ${BOLD_WHITE}${depends_on}${DEFCOLOR}\n"
    done
  fi
  printf $YELLOW"Analyzing branch dependencies done"$DEFCOLOR'\n\n'

  handle_rebase_failure() {
    local branch=$1
    local depends_on=$2
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
      printf "${RED}Rebasing ${GREEN}$branch${RED} to ${GREEN}$depends_on${RED} failed. Choose an option:\n"
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

  for branch in "${impacted_only_branches[@]}"; do
    printf "${YELLOW}Resetting ${BOLD_WHITE}${branch}${YELLOW} to origin/${branch} ...${DEFCOLOR}\n"
    git checkout -q -B "$branch" "origin/$branch"
  done

  # Rebase branches in order
  for branch in "${sorted_branches[@]}"; do
    depends_on=$(map_get "$branch_deps" "$branch" || true)
    [[ -n $depends_on ]] || depends_on=$base
    printf "${YELLOW}Rebasing ${BOLD_WHITE}${branch}${YELLOW} to ${depends_on} ..."$DEFCOLOR"\n"
    git checkout -q $branch
    git rebase $depends_on 1> /dev/null

    if [[ $? != 0 ]] && ! handle_rebase_failure $branch $depends_on; then
      printf $RED"Removing $branch from later steps due to rebase failure"$DEFCOLOR'\n'
      unmerged_branches=($(filter_branch_out "$branch" "${unmerged_branches[@]}"))
      branches_to_push=($(filter_branch_out "$branch" "${branches_to_push[@]}"))
    fi
    # sleep required to give git time to unlock rebase/merge locks
    sleep 2
  done

  sorted_merge_branches=($(sort_branches_by_distance "${unmerged_branches[@]}"))
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

for i in "${sorted_merge_branches[@]}"; do
  printf $YELLOW"Merging ${BOLD_WHITE}${i}${YELLOW} to ${targetBranch} ..."$DEFCOLOR'\n'
  merge_output=$(git merge --no-ff --no-edit $i 2>&1)
  merge_return_code=$?
  
  # Check if branch was already merged
  if [[ $merge_output == *"Already up to date."* ]]; then
    printf $YELLOW"${BOLD_WHITE}Branch ${i} was already merged to ${base} in the past"$DEFCOLOR'\n'
    continue
  fi
  # If the merge stops on conflicts, either auto-apply rerere, let the user
  # resolve and continue, skip this branch, or abort the whole script.
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
  STACKED_BRANCHES_SKIP=1 git push --force-with-lease --no-verify origin "${branches_to_push[@]}" "$targetBranch"
else
  STACKED_BRANCHES_SKIP=1 git push --force-with-lease origin "${branches_to_push[@]}" "$targetBranch"
fi
