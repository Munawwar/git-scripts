# git-defaults.sh

Some git defaults we set on our systems. Check comments in the file for more details.

# merges.sh

Tells you all the branches that were merged to a specified branch.

```sh
merges.sh release
```
will tell you all the branches merged into release branch (from oldest merge to newest, duplicates removed).

# rc.sh ("re-create" branch script)

Script helps you create a fresh branch with only the features that you wanted to test/release.

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

step 0 - "learns" about past merge conflict resolutions done on existing target branch (develop or release), so that merging branches on step number 3 is easier. To understand more about it read about [git rerere ("reuse recorded resolution")](https://git-scm.com/book/en/v2/Git-Tools-Rerere) and [rerere-train.sh](https://github.com/git/git/blob/master/contrib/rerere-train.sh).

step 1 - resets target branch to master

step 2 - rebases all features branches with latest master
(rebasing long running branch is problematic. I suggest these be excluded and merged separately)

step 3 - merges each feature branch one-by-one to target branch. If it hits a merge a conflict, it waits till you manually intervene & fix the merge OR allows you to skip the merge & continue OR allows you to abort the script entirely.

step 4 - prompts to force push target branch and the rebased feature branches (uses `--force-with-lease` flag)

## Solution for long running branches

long running branch means e.g a branch that touches 100s of files that is taking several weeks of development.

1. merge master to long running branch
2. deploy all other branches first. i.e. dont add the long running branches as part of rc.sh command
3. merge long running branches to target branch after rc push

Tip: Enable git rerere (`git config rerere.enabled true`) so that you dont have to redo previously resolved merge conflicts if you need to re-create the branch again.
Use [rerere-train.sh](https://github.com/git/git/blob/master/contrib/rerere-train.sh) to train rerere with old resolutions done by other team members. To find which commit from which to train rerere use `branch-point.sh` (example usage `branch-point.sh dev` will give the commit from which `dev` branch was branched out from, relative to master branch)

# close-release.sh

After deploying from release branch, this script traverses through all git repos and creates a "backup" branch from master's commit and merges the release branch to master. 