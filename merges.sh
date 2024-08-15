#!/bin/bash

# Prints merge branches between master and given branch
# Usage: merges.sh develop
#
# remember to do:
# chmod +x merges.sh
#
# Prints from oldest merge to latest
# Tries to find branch names from git and github PR's auto commit message pattern
# and also removes duplicates (in order)

git fetch origin master $1
printf "\nMerged branches:\n"
# Steps:
# List git log message of merge commits from oldest to newest in order
# try to remove surrounding text to get only branch names
# remove duplicates
git log --format="%s" --merges --reverse origin/master..origin/$1 | cat - \
  | sed -E "s~Merge branch '([-a-zA-Z0-9]+)' into .+~\1~" \
  | sed -E "s~Merge (remote-tracking )?branch '.+/([-\.a-zA-Z0-9]+)' into .+~\2~" \
  | sed -E "s~Merge pull request #[0-9]+ from Carriyo/(.+)~\1~" \
  | awk '!x[$0]++'
