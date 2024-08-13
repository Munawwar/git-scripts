#!/usr/bin/env bash

# Prints the commit from which a given branch was branched out from (relative to master branch).
# Usage branch-point.sh <branch>

diff --old-line-format='' --new-line-format='' \
  <(git rev-list --first-parent "${1:-origin/master}") \
  <(git rev-list --first-parent "${2:-origin/$1}") \
| head -1