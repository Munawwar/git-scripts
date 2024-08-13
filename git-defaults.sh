# Push should auto setup rebase from the remote on next git pull --rebase
git config --global --add --bool push.autoSetupRemote true

# We sometimes re-create release branch. We don't want do resolve same merge conflicts again.
# Git rerere remembers past merge conflict resolutons.
# Also check rerere-train.sh script (https://github.com/git/git/blob/master/contrib/rerere-train.sh)
git config --global rerere.enabled true

# Disable fast-forward when explicitly merging. The merge commit is used for creating a changelog
git config --global --add merge.ff false

# `git branch-point` - To know which commit the current branch forked off from
git config --global alias.branch-point '!bash -c '\''diff --old-line-format='' --new-line-format='' <(git rev-list --first-parent "${1:-master}") <(git rev-list --first-parent "${2:-HEAD}") | head -1'\'' -'