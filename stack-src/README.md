# stack-check and stack-push

These portable Nim executables replace `stacked.js` and `stacked-push.js`:

- `stack-check.com` runs as a Git `pre-push` hook. It checks the exact commit
  IDs Git intends to push, reports branches that would become unstacked, and
  lets the user continue or abort. It never changes branches.
- `stack-push.com` finds affected branches, rebases them from parents to
  descendants, and pushes all corrected tips in one atomic operation.

The executables are Actually Portable Executables and do not require Node.js,
fnm, or npm dependencies. Nim's ORC memory management reclaims strings,
sequences, and objects automatically.

## Install

Install the commands from the repository root:

```sh
install -m755 stack-check.com ~/.local/bin/stack-check
install -m755 stack-push.com ~/.local/bin/stack-push
```

Install `stack-check` as a hook in a repository:

```sh
cp stack-check.com /path/to/repository/.git/hooks/pre-push
chmod +x /path/to/repository/.git/hooks/pre-push
```

`origin` is already the default for `stack-push`. The hook automatically uses
the remote Git is pushing to, so aliases that hard-code `--remote=origin` are
not recommended.

## Hook integration

```text
STACK_CHECK_SKIP=1
```

The base and release list are configured per invocation:

```sh
stack-push --base=main --release-branches="main staging" feature-a
```

`STACK_CHECK_SKIP` is set internally by `stack-push` for its final child
`git push`. It skips only `stack-check`; other pre-push validations still run.

## Usage

```sh
stack-push feature-a
stack-push -y origin feature-a feature-b
stack-push --dry-run feature-a
stack-push --force feature-a
```

`-y` or `--yes` performs all required repairs without prompting.

`-n` or `--dry-run` prints the detected ancestor/descendant stack and required
repairs, then exits without changing local branches or pushing. Combine it with
`--no-fetch` to avoid updating remote-tracking refs.

`stack-push` options:

```text
-y, --yes                    restack without prompting
-f, --force                  allow an intentional remote-history rewrite
-n, --dry-run                show the detected stack without changing or pushing branches
    --no-fetch               use existing remote-tracking refs
    --remote=NAME            push remote (default: origin)
    --base=BRANCH            stack base (default: remote HEAD)
    --release-branches=LIST  space-separated excluded branches
                            default: dev test release master main
```

By default, `stack-push` rejects a local tip that would remove commits already
present on the remote. `-f` or `--force` confirms that the rewrite is
intentional, but never authorizes dropping commits that arrive while the
command is running.

Before changing a local branch, `stack-push` prints its original abbreviated
commit ID once. This provides a recovery reference if the branch needs to be
restored manually.

## How stack detection works

Unless `--no-fetch` is supplied, the tools fetch and prune every branch under
`refs/heads/*`. Shallow clones are unshallowed, so ancestry checks use the
complete reachable commit graph.

Branches already merged into the configured base, branches in the release
list, and branches inactive for more than two months are excluded. Explicitly
requested branches are always included. For every remaining branch, the
nearest branch tip in its ancestry is treated as its parent. The proposed push
commit IDs are then applied to that graph to find children and descendants
that require restacking.

Without `--base`, the tools use the selected remote's symbolic HEAD, falling
back to `main` and then `master` when that symbolic ref is unavailable.

Git does not record a declared stack parent. The configured base wins ties.
Other branch names at the same commit are treated as equivalent, with a branch
included in the push preferred as the parent. The operation aborts if
equivalent parents would move to different commits.

`stack-push` snapshots remote-tracking tips before fetching. Remote commits
that arrive during the fetch are preserved by replaying local-only commits on
top of them. Concurrent changes that cannot be safely combined cause the
operation to abort.

The final push uses an exact force-with-lease check for every branch and
`--atomic`, so either every branch is updated or none is.

## Build

Prebuilt APE binaries are committed at the repository root. Rebuilding
requires Nim 2.2 or newer at `.toolchain/nim/bin/nim` and Cosmopolitan at
`.toolchain/cosmocc/bin/cosmocc`.

From the repository root:

```sh
make -C stack-src
make -C stack-src test
```

Build intermediates remain under `stack-src/build/`; only `stack-check.com`
and `stack-push.com` are copied to the repository root.

The integration suite creates disposable local Git remotes and covers stack
planning, fetch races, recovery failures, atomic pushes, and SHA-256 object IDs.

Source layout:

- `stack_check.nim` is the check-only entry point.
- `stack_push.nim` is the push/restack entry point.
- `stack_shared.nim` contains the shared Git and stack-graph logic.

The build uses `--mm:orc` for deterministic automatic memory management and
`-d:useFork` because Nim's `posix_spawn` path could not launch the host Git
executable in a Cosmopolitan build.
