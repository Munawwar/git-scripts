# git-defaults.sh

Some git defaults we set on our systems. Check comments in the file for more details.

# merges.sh

Tells you all the branches that were merged to a specified branch.

```sh
merges.sh release
```
will tell you all the branches merged into release branch (from oldest merge to newest, duplicates removed).

# rc.sh ("re-create" branch script)

Script helps you create a fresh branch with only the branches that you want to test/release.

```sh
rc.sh -t release branch1 branch2
```
will create a new release branch forked from latest master, with `branch1` and `branch2` merged into it. Script will attempt to rebase `branch1` and `branch2` to latest master before merge as well.

rc.sh can re-create a branch, by auto-detecting the branches merged into the target branch.

```sh
rc.sh -t release
```

You can add or remove branches from the auto-detected list of branches to be merged into the target branch.

```sh
rc.sh -t release --add branchX --remove branch5
```

Read rc.sh header comments to understand the different flags that can be used.

## Before running rc.sh script
1. you should not have any local changes (`git stash` before running script)
2. push any local branches before running script (why because script doesn't know whether your local branches are stale or has new commits.. so it always assumes whatever is pushed is the latest)

## What does rc.sh script do?

Step 1 - Resets target branch to base branch (base branch is `master` by default)

Step 2 - "Learns" about past merge conflict resolutions done on existing target branch (develop or release), so that merging branches on step number 4 is easier. To understand more about it read about [git rerere ("reuse recorded resolution")](https://git-scm.com/book/en/v2/Git-Tools-Rerere) and [rerere-train.sh](https://github.com/git/git/blob/master/contrib/rerere-train.sh).

Tip: Enable git rerere (`git config rerere.enabled true`) so that you dont have to redo previously resolved merge conflicts if you need to re-create the branch again.

Step 3 - Rebases all branches with latest master. It tries to detect stacked branches and rebase in-order. If there is an issue rebasing you get option to skip the branch from being rebased and merged.

Tip: Rebasing long running branches are problematic. [I suggest to exclude them and merge them separately](#solution-for-long-running-branches).

Step 4 - Merges each branch one-by-one to target branch. If it hits a merge a conflict, it checks if there was a past merge conflict resolution. If it does have one then uses that and proceeds. Else it waits till you manually intervene & fix the merge OR allows you to skip the merge & continue OR allows you to abort the script entirely.

Step 5 - If auto-approval flag wasn't used, then prompts to force push target branch and the rebased branches (uses `--force-with-lease` flag)

## Solution for long running branches

long running branch means e.g a branch that touches 100s of files that is taking several weeks of development.

1. merge master to long running branch
2. deploy all other branches first. i.e. dont add the long running branches as part of rc.sh command
3. merge long running branches to target branch after rc push

# close-release.sh

After deploying from release branch, this script traverses through all git repos and creates a "backup" branch from master's commit and merges the release branch to master. 
