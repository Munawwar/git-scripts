#!/usr/bin/env bash
# Usage close-release.sh git-repo-1 git-repo-2 ...

# Goes through each directory within current working directory and
# 1. creates a backup branch from current master
# 2. merges release branch into master

# remember to do:
# chmod +x close-release.sh

GREEN='\x1B[1;32m'
YELLOW='\x1B[1;33m'
DEFCOLOR='\x1B[0;m'


for d in "${@:1}"; do
    cd $d

    git fetch -q origin master release 2> /dev/null
    if [[ $? != 0 ]]; then
        cd ..
        continue
    fi

    # Create backup branch from current master
    git stash -q
    git checkout -q backup 1> /dev/null
    git reset --hard origin/master 1> /dev/null

    # Merge release branch to master
    git checkout -q release 1> /dev/null
    git reset --hard origin/release 1> /dev/null
    git checkout -q master 1> /dev/null
    git reset --hard origin/master 1> /dev/null
    git merge --no-ff --no-edit release 1> /dev/null

    # Number of changes
    count=$(git log --oneline backup..master | cat | wc -l | tr -d ' ')
    if [[ $count != "0" ]]; then
        git push origin master backup 1> /dev/null
        printf $GREEN"Merged $d"$DEFCOLOR'\n'
    fi

    if [[ $count == "0" ]]; then
        printf $YELLOW"No changes for $d. Skipping merge."$DEFCOLOR'\n'
    fi

    cd ..;
done