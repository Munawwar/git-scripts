import std/[os, osproc, posix, streams, strutils]

const
  ZeroOid = "0000000000000000000000000000000000000000"
  DefaultReleases = "dev test release master main"
  NoTtyError = "push would unstack branches; aborting because no interactive terminal is available."

type
  ## One active remote branch and its inferred historical stack relationship.
  ## `historySha` is the command-start tip, `remoteSha` is the post-fetch tip,
  ## and `futureSha` is the proposed or repaired tip used to detect drift.
  Branch = object
    name, historySha, remoteSha, futureSha, localSha: string
    parent: int
    depth: int
    pushed, deleted, stale, needsSync: bool

  ## One destination branch and object ID proposed by Git or stack-push.
  Update = object
    localSha, remoteName, fetchedRemoteSha, syncBaseSha: string
    needsSync: bool

  ## One remote-tracking tip captured before or after fetching.
  RemoteTip = object
    name, sha: string

  CommandResult = tuple[output: string, status: int]

## Runs Git without a shell, so branch and remote names remain literal
## arguments. Commands that may invoke hooks or show rebase progress inherit
## the terminal; query commands merge stderr into their captured output.
proc git(args: openArray[string]; parentStreams = false): CommandResult =
  let options =
    if parentStreams: {poUsePath, poParentStreams}
    else: {poUsePath, poStdErrToStdOut}
  try:
    let process = startProcess("git", args = args, options = options)
    defer: process.close()
    if parentStreams:
      result.status = process.waitForExit()
    else:
      result.output = process.outputStream.readAll()
      result.status = process.waitForExit()
  except OSError:
    result.status = 127

proc fail(message: string): int =
  stderr.writeLine("Error: " & message)
  1

proc findTip(tips: openArray[RemoteTip]; name: string): int =
  for i, tip in tips:
    if tip.name == name:
      return i
  -1

proc findBranch(branches: openArray[Branch]; name: string): int =
  for i, branch in branches:
    if branch.name == name:
      return i
  -1

proc isAncestor(ancestor, descendant: string): bool =
  ancestor.len > 0 and descendant.len > 0 and
    git(["merge-base", "--is-ancestor", ancestor, descendant]).status == 0

## Captures the lease boundary and historical graph before a fetch can move
## remote-tracking refs.
proc loadRemoteTips(remote: string): tuple[tips: seq[RemoteTip], ok: bool] =
  let response = git([
    "for-each-ref",
    "--format=%(refname:strip=3) %(objectname)",
    "refs/remotes/" & remote
  ])
  if response.status != 0:
    return
  result.ok = true
  for line in response.output.splitLines():
    let fields = line.splitWhitespace()
    if fields.len >= 2 and fields[0] != "HEAD":
      result.tips.add RemoteTip(name: fields[0], sha: fields[1])

## Enumerates open stack branches after fetching. Branches already merged into
## the base and configured release branches do not participate in restacking.
proc enumerateBranches(
  remote, baseSha, releases: string;
  startingTips: openArray[RemoteTip]
): tuple[branches: seq[Branch], ok: bool] =
  let response = git([
    "for-each-ref",
    "--format=%(refname:strip=3) %(objectname)",
    "--no-merged=" & baseSha,
    "refs/remotes/" & remote
  ])
  if response.status != 0:
    return
  result.ok = true
  let excluded = releases.splitWhitespace()
  for line in response.output.splitLines():
    let fields = line.splitWhitespace()
    if fields.len < 2 or fields[0] == "HEAD" or fields[0] in excluded:
      continue
    let startingIndex = startingTips.findTip(fields[0])
    result.branches.add Branch(
      name: fields[0],
      historySha:
        if startingIndex >= 0: startingTips[startingIndex].sha
        else: fields[1],
      remoteSha: fields[1],
      futureSha: fields[1],
      parent: -1
    )

## Infers each branch's nearest historical ancestor as its parent. Two names at
## the same commit are equivalent; a pushed name wins that tie, while divergent
## equally-near parents are rejected because one linear rebase cannot keep both.
##
## Example historical graph (`--` means "is an ancestor of"):
##
##   origin/master -- origin/A -- origin/B -- C
##                                      `--- D
##
## B is the parent of both C and D, while A is the parent of B. The configured
## base wins only when no closer active branch tip exists.
proc inferParents(branches: var seq[Branch]; baseSha: string): bool =
  for i in 0 ..< branches.len:
    var bestDistance = int.high
    if isAncestor(baseSha, branches[i].historySha):
      let response = git([
        "rev-list", "--ancestry-path", "--count",
        baseSha & ".." & branches[i].historySha
      ])
      if response.status != 0:
        stderr.writeLine("Error: could not measure ancestry from the configured base.")
        return false
      try:
        bestDistance = response.output.strip().parseInt()
      except ValueError:
        stderr.writeLine("Error: Git returned an invalid ancestry distance.")
        return false

    for j in 0 ..< branches.len:
      if i == j or not isAncestor(branches[j].historySha, branches[i].historySha):
        continue
      let response = git([
        "rev-list", "--ancestry-path", "--count",
        branches[j].historySha & ".." & branches[i].historySha
      ])
      if response.status != 0:
        stderr.writeLine("Error: could not measure ancestry between stack branches.")
        return false
      var distance: int
      try:
        distance = response.output.strip().parseInt()
      except ValueError:
        stderr.writeLine("Error: Git returned an invalid ancestry distance.")
        return false

      if distance > 0 and distance < bestDistance:
        branches[i].parent = j
        bestDistance = distance
      elif distance > 0 and distance == bestDistance and branches[i].parent >= 0:
        let current = branches[i].parent
        if branches[current].historySha != branches[j].historySha:
          stderr.writeLine(
            "Error: " & branches[i].name & " has equally near parents " &
            branches[current].name & " and " & branches[j].name &
            " on different commits."
          )
          return false

        # Aliases at one commit are harmless until both move differently:
        #
        #   A0 (origin/A, origin/A-alias) -- B
        #        | push A -> A1
        #        ` push A-alias -> A2       A1 != A2, so B has no single parent.
        if branches[j].pushed and not branches[current].pushed:
          branches[i].parent = j
        elif branches[j].pushed and branches[current].pushed and
            branches[j].futureSha != branches[current].futureSha:
          stderr.writeLine(
            "Error: equivalent parents " & branches[current].name & " and " &
            branches[j].name & " would diverge in this push; " &
            branches[i].name & " cannot be stacked on both."
          )
          return false
  true

## Compares historical parent edges with proposed tips, then propagates drift
## from stale parents to descendants in depth order.
##
## Rewriting A makes B stale directly; C and D become stale by propagation:
##
##   history:  origin/master -- A0(origin/A) -- B0(origin/B) -- C
##                                                   `---------- D
##   proposed: origin/master -- A1(A)
##
## A1 is not an ancestor of B0. Deleting A has the same effect: B loses its
## parent entirely, and every surviving descendant must be repaired.
proc markStaleBranches(branches: var seq[Branch]): int =
  for i in 0 ..< branches.len:
    var cursor = branches[i].parent
    while cursor >= 0:
      inc branches[i].depth
      cursor = branches[cursor].parent
    result = max(result, branches[i].depth)
    if not branches[i].deleted and branches[i].parent >= 0:
      let parent = branches[i].parent
      branches[i].stale = branches[parent].deleted or
        not isAncestor(branches[parent].futureSha, branches[i].futureSha)
      let parentRewritten =
        not isAncestor(branches[parent].historySha, branches[parent].futureSha)
      if not branches[i].stale and parentRewritten and
          isAncestor(branches[parent].historySha, branches[i].futureSha):
        branches[i].stale = true

  for depth in 1 .. result:
    for i in 0 ..< branches.len:
      let parent = branches[i].parent
      if not branches[i].deleted and branches[i].depth == depth and
          parent >= 0 and branches[parent].stale:
        branches[i].stale = true

## Applies proposed tips to the remote graph. A new destination branch is added
## when it is still open relative to the base, even though no remote tip exists.
proc applyUpdates(
  branches: var seq[Branch];
  updates: openArray[Update];
  releases, baseSha: string;
  includeLocalSha: bool
) =
  let excluded = releases.splitWhitespace()
  for update in updates:
    let index = branches.findBranch(update.remoteName)
    if index >= 0:
      branches[index].pushed = true
      branches[index].deleted = update.localSha == ZeroOid
      branches[index].futureSha = update.localSha
      if includeLocalSha:
        branches[index].localSha = update.localSha
    elif update.localSha != ZeroOid and update.remoteName notin excluded and
        not isAncestor(update.localSha, baseSha):
      branches.add Branch(
        name: update.remoteName,
        historySha: update.localSha,
        futureSha: update.localSha,
        localSha: if includeLocalSha: update.localSha else: "",
        parent: -1,
        pushed: true
      )

## Fetches every remote branch with complete history. Restricted fetch
## refspecs and shallow clones would otherwise make ancestry checks incomplete.
proc fetchRemote(remote: string; doFetch: bool): bool =
  if git(["remote", "get-url", remote]).status != 0:
    stderr.writeLine("Error: the push remote must be a configured Git remote.")
    return false
  if not doFetch:
    return true
  var args = @["fetch", "--quiet", "--prune"]
  let shallow = git(["rev-parse", "--is-shallow-repository"])
  if shallow.status == 0 and shallow.output.strip() == "true":
    args.add "--unshallow"
  args.add remote
  args.add "+refs/heads/*:refs/remotes/" & remote & "/*"
  if git(args, parentStreams = true).status != 0:
    stderr.writeLine("Error: failed to fetch complete history from the push remote.")
    return false
  true

## Resolves an explicit base or tries the remote HEAD, main, then master. The
## fetched tip drives future ancestry while the command-start tip drives
## historical parent inference.
proc resolveBase(
  remote, requestedBase: string;
  startingTips: openArray[RemoteTip]
): tuple[name, baseSha, historyBaseSha: string, ok: bool] =
  var candidates: seq[string]
  if requestedBase.len > 0:
    candidates.add requestedBase
  else:
    let head = git([
      "symbolic-ref", "--quiet", "--short", "refs/remotes/" & remote & "/HEAD"
    ])
    let prefix = remote & "/"
    let headName = head.output.strip()
    if head.status == 0 and headName.startsWith(prefix) and
        headName.len > prefix.len:
      candidates.add headName[prefix.len .. ^1]
    for fallback in ["main", "master"]:
      if fallback notin candidates:
        candidates.add fallback

  for candidate in candidates:
    let response = git([
      "rev-parse", "--verify", "refs/remotes/" & remote & "/" & candidate
    ])
    if response.status == 0:
      result.name = candidate
      result.baseSha = response.output.strip()
      break
  if result.name.len == 0:
    if requestedBase.len > 0:
      stderr.writeLine("Error: the configured base branch has no remote-tracking ref.")
    else:
      stderr.writeLine("Error: could not infer the remote base; use --base=BRANCH.")
    return

  result.historyBaseSha = result.baseSha
  let startingIndex = startingTips.findTip(result.name)
  if startingIndex >= 0:
    result.historyBaseSha = startingTips[startingIndex].sha
  result.ok = true

proc prompt(message: string; choices: openArray[string]):
    tuple[answer: string, available: bool] =
  var tty: File
  if not open(tty, "/dev/tty", fmReadWrite):
    return
  result.available = true
  defer: tty.close()
  tty.write("\n" & message & "\n")
  for choice in choices:
    tty.write("  " & choice & "\n")
  tty.write("Choice: ")
  tty.flushFile()
  try:
    result.answer = tty.readLine().strip().toLowerAscii()
  except IOError:
    discard

## Replays only commits after `oldBase` onto `newBase`. On failure, aborting the
## current rebase and restoring the original checkout are attempted separately
## so the user gets an accurate recovery state.
proc replayCommits(
  name, newBase, oldBase, restore: string
): tuple[tip: string, ok: bool] =
  if git(["rebase", "--onto", newBase, oldBase, name], parentStreams = true).status != 0:
    let abortOk = git(["rebase", "--abort"]).status == 0
    let restoreOk = git(["checkout", "--quiet", restore], parentStreams = true).status == 0
    if not abortOk and not restoreOk:
      stderr.writeLine("Error: rebase failed; neither its automatic abort nor the original checkout restoration succeeded.")
    elif not abortOk:
      stderr.writeLine("Error: rebase failed; its automatic abort failed, but the original checkout was restored.")
    elif not restoreOk:
      stderr.writeLine("Error: rebase was aborted, but the original checkout could not be restored.")
    else:
      stderr.writeLine("Error: rebase failed; it was aborted and the original checkout was restored.")
    return
  let response = git(["rev-parse", "refs/heads/" & name])
  if response.status != 0:
    stderr.writeLine("Error: could not resolve a branch after rebasing it.")
    return
  result = (response.output.strip(), true)

proc runStackCheck*(): int =
  if existsEnv("STACK_CHECK_SKIP"):
    return 0

  # Parse hook configuration before consuming Git's proposed ref updates.
  var
    remote = "origin"
    remoteExplicit = false
    doFetch = true
    base = ""
    releases = DefaultReleases
    targets: seq[string]
  for arg in commandLineParams():
    if arg == "--no-fetch":
      doFetch = false
    elif arg.startsWith("--remote="):
      remote = arg[9 .. ^1]
      remoteExplicit = true
    elif arg.startsWith("--base="):
      base = arg[7 .. ^1]
    elif arg.startsWith("--release-branches="):
      releases = arg[19 .. ^1]
    elif arg in ["-h", "--help"]:
      echo "Usage: stack-check [options] [remote] [remote-url]"
      echo "Git pre-push hook; reads ref updates from stdin."
      echo "      --no-fetch               use existing remote-tracking refs"
      echo "      --remote=NAME            override the hook remote"
      echo "      --base=BRANCH            stack base (default: remote HEAD)"
      echo "      --release-branches=LIST  space-separated excluded branches"
      echo "  -h, --help                   show this help"
      return 0
    elif arg.startsWith("-"):
      return fail("unknown option; use --help for usage.")
    else:
      targets.add arg
  if targets.len > 0 and not remoteExplicit:
    remote = targets[0]
  if posix.isatty(stdin.getFileHandle().cint) != 0:
    return fail("stack-check expects Git pre-push records on stdin; use --help for usage.")

  var updates: seq[Update]
  for line in stdin.lines:
    let fields = line.splitWhitespace()
    if fields.len >= 3 and fields[2].startsWith("refs/heads/"):
      updates.add Update(
        localSha: fields[1],
        remoteName: fields[2][11 .. ^1]
      )
  if updates.len == 0:
    return 0

  # Snapshot first: fetching may move refs and must not rewrite the historical
  # graph used to decide which parent edge a proposed push would break.
  let initial = loadRemoteTips(remote)
  if not initial.ok:
    return fail("could not snapshot remote-tracking branches before fetch.")
  if not fetchRemote(remote, doFetch):
    return 1
  let baseInfo = resolveBase(remote, base, initial.tips)
  if not baseInfo.ok:
    return 1
  var branchInfo = enumerateBranches(remote, baseInfo.baseSha, releases, initial.tips)
  if not branchInfo.ok:
    return fail("could not enumerate remote branches.")

  # Evaluate the exact destination SHAs supplied to the hook. The checker never
  # changes local branches; it only models the graph that would exist afterward.
  applyUpdates(branchInfo.branches, updates, releases, baseInfo.baseSha, false)
  if not inferParents(branchInfo.branches, baseInfo.historyBaseSha):
    return 1
  discard markStaleBranches(branchInfo.branches)

  # Report every broken edge, including descendants omitted from the push.
  var staleCount = 0
  for branch in branchInfo.branches:
    if branch.stale:
      inc staleCount
      let parentName =
        if branch.parent >= 0: branchInfo.branches[branch.parent].name
        else: baseInfo.name
      let pushNote =
        if branch.pushed: " (included in this push)"
        else: " (OMITTED from this push)"
      stderr.writeLine("• " & branch.name & " must be restacked onto " &
        parentName & pushNote)
  if staleCount == 0:
    stderr.writeLine("Stack check passed.")
    return 0

  let response = prompt(
    "Push would unstack " & $staleCount & " branch(es).",
    ["[p] continue this push without repairing the stack", "[a] abort (default)"]
  )
  if not response.available:
    return fail(NoTtyError)
  if response.answer.startsWith("p"):
    return 0
  fail("push aborted.")

proc runStackPush*(): int =
  # Parse configuration and collect the requested local branches.
  var
    remote = "origin"
    remoteExplicit, autoYes, allowRewrite = false
    doFetch = true
    base = ""
    releases = DefaultReleases
    targets: seq[string]
  for arg in commandLineParams():
    if arg in ["-y", "--yes"]:
      autoYes = true
    elif arg in ["-f", "--force"]:
      allowRewrite = true
    elif arg == "--no-fetch":
      doFetch = false
    elif arg.startsWith("--remote="):
      remote = arg[9 .. ^1]
      remoteExplicit = true
    elif arg.startsWith("--base="):
      base = arg[7 .. ^1]
    elif arg.startsWith("--release-branches="):
      releases = arg[19 .. ^1]
    elif arg in ["-h", "--help"]:
      echo "Usage: stack-push [options] [remote] [branch ...]"
      echo "  -y, --yes                    restack without prompting"
      echo "  -f, --force                  allow removal of commits present when the command started"
      echo "      --no-fetch               use existing remote-tracking refs"
      echo "      --remote=NAME            push remote (default: origin)"
      echo "      --base=BRANCH            stack base (default: remote HEAD)"
      echo "      --release-branches=LIST  space-separated excluded branches"
      echo "  -h, --help                   show this help"
      return 0
    elif arg.startsWith("-"):
      return fail("unknown option; use --help for usage.")
    else:
      targets.add arg

  # A configured remote may be the first positional argument. With no branch
  # arguments, symbolic-ref avoids guessing a branch from a detached HEAD.
  var targetStart = 0
  if targets.len > 0 and not remoteExplicit and
      git(["config", "--get", "remote." & targets[0] & ".url"]).status == 0:
    remote = targets[0]
    targetStart = 1
  if targets.len == targetStart:
    let current = git(["symbolic-ref", "--quiet", "--short", "HEAD"])
    if current.status != 0:
      return fail("could not determine the current branch.")
    targets.add current.output.strip()

  var updates: seq[Update]
  for i in targetStart ..< targets.len:
    let response = git(["rev-parse", "--verify", "refs/heads/" & targets[i]])
    if response.status != 0:
      return fail("a requested local branch could not be resolved.")
    updates.add Update(localSha: response.output.strip(), remoteName: targets[i])

  # Keep snapshots from both sides of the fetch. Their difference distinguishes
  # pre-existing rewrites from commits that arrived while this command ran.
  let initial = loadRemoteTips(remote)
  if not initial.ok:
    return fail("could not snapshot remote-tracking branches before fetch.")
  if not fetchRemote(remote, doFetch):
    return 1
  let fetched = loadRemoteTips(remote)
  if not fetched.ok:
    return fail("could not read remote-tracking branches after fetch.")

  # A newly fetched tip may already be in the local history. Otherwise, local
  # commits based on the starting tip must be replayed; unrelated divergence is
  # rejected even when --force was supplied.
  #
  #   command start: A0(origin/A) -- L(local A)
  #   after fetch:   A0 ---------- R(origin/A)
  #   repaired:      A0 -- R -- L'(local A)
  #
  # Only commits in A0..L are replayed. If the remote branch appeared from
  # nothing, disappeared, or no longer shares A0, the safe action is to abort.
  var syncCount = 0
  for i in 0 ..< updates.len:
    let startIndex = initial.tips.findTip(updates[i].remoteName)
    let fetchIndex = fetched.tips.findTip(updates[i].remoteName)
    let startingSha = if startIndex >= 0: initial.tips[startIndex].sha else: ""
    if fetchIndex >= 0:
      updates[i].fetchedRemoteSha = fetched.tips[fetchIndex].sha
    let fetchedSha = updates[i].fetchedRemoteSha
    let remoteChanged = startingSha != fetchedSha
    if remoteChanged:
      if startingSha.len == 0 or fetchedSha.len == 0:
        return fail(remote & "/" & updates[i].remoteName &
          " appeared or disappeared while stack-push was fetching; inspect it and retry.")
      if isAncestor(fetchedSha, updates[i].localSha):
        discard
      elif isAncestor(startingSha, fetchedSha) and
          isAncestor(startingSha, updates[i].localSha):
        updates[i].needsSync = true
        updates[i].syncBaseSha = startingSha
        inc syncCount
      else:
        return fail(remote & "/" & updates[i].remoteName &
          " and its local branch both changed while fetching; resolve them manually and retry.")
    elif fetchedSha.len > 0 and not isAncestor(fetchedSha, updates[i].localSha) and
        not allowRewrite:
      return fail("local " & updates[i].remoteName & " would remove commits from " &
        remote & "/" & updates[i].remoteName & "; rerun with --force if intentional.")

  # Build the complete remote graph, apply requested future tips, and infer
  # parent edges exclusively from the command-start history.
  let baseInfo = resolveBase(remote, base, initial.tips)
  if not baseInfo.ok:
    return 1
  var branchInfo = enumerateBranches(remote, baseInfo.baseSha, releases, initial.tips)
  if not branchInfo.ok:
    return fail("could not enumerate remote branches.")
  applyUpdates(branchInfo.branches, updates, releases, baseInfo.baseSha, true)
  if not inferParents(branchInfo.branches, baseInfo.historyBaseSha):
    return 1
  let maxDepth = markStaleBranches(branchInfo.branches)

  # Protect omitted stale descendants before adding them to the operation. A
  # local branch may contain unpublished work, but cannot replace fetched work.
  #
  #   remote:   master -- A0 -- B0
  #   proposed: master -- A1          (only A was requested)
  #
  # If local B is missing, it is later created at B0 and rebased onto A1. If it
  # exists, its unpublished commits are retained only when they also retain all
  # fetched remote commits.
  for i in 0 ..< branchInfo.branches.len:
    if not branchInfo.branches[i].stale or branchInfo.branches[i].pushed:
      continue
    let local = git(["rev-parse", "--verify",
      "refs/heads/" & branchInfo.branches[i].name])
    if local.status != 0:
      continue
    branchInfo.branches[i].localSha = local.output.strip()
    let startIndex = initial.tips.findTip(branchInfo.branches[i].name)
    if startIndex < 0:
      return fail(remote & "/" & branchInfo.branches[i].name &
        " appeared while stack-push was fetching; inspect it and retry.")
    let
      startingSha = branchInfo.branches[i].historySha
      fetchedSha = branchInfo.branches[i].remoteSha
      localSha = branchInfo.branches[i].localSha
    if startingSha != fetchedSha:
      if isAncestor(fetchedSha, localSha):
        discard
      elif isAncestor(startingSha, fetchedSha) and isAncestor(startingSha, localSha):
        branchInfo.branches[i].needsSync = true
        inc syncCount
      else:
        return fail("omitted branch " & branchInfo.branches[i].name & " and " &
          remote & "/" & branchInfo.branches[i].name &
          " both changed while fetching; resolve them manually and retry.")
    elif not isAncestor(fetchedSha, localSha) and not allowRewrite:
      return fail("local " & branchInfo.branches[i].name &
        " would remove commits from " & remote & "/" & branchInfo.branches[i].name &
        "; rerun with --force if intentional.")

  # Summarize all required local changes before asking for one decision.
  for update in updates:
    if update.needsSync:
      stderr.writeLine("• " & update.remoteName &
        " received remote commits during fetch; local commits must be replayed onto " &
        remote & "/" & update.remoteName)
  var staleCount = 0
  for branch in branchInfo.branches:
    if branch.needsSync:
      stderr.writeLine("• " & branch.name &
        " received remote commits during fetch; local commits must be replayed onto " &
        remote & "/" & branch.name)
    if branch.stale:
      inc staleCount
      let parentName =
        if branch.parent >= 0: branchInfo.branches[branch.parent].name
        else: baseInfo.name
      let pushNote =
        if branch.pushed: " (included in this push)"
        else: " (OMITTED from this push)"
      stderr.writeLine("• " & branch.name & " must be restacked onto " &
        parentName & pushNote)

  let workCount = staleCount + syncCount
  var doRestack = workCount > 0
  var answer = if autoYes: "r" else: ""
  if workCount > 0 and not autoYes:
    var choices = @["[r] restack and push every affected branch"]
    if syncCount == 0:
      choices.add "[p] push anyway, leaving the stack broken"
    choices.add "[a] abort (default)"
    let response = prompt(
      "Stack push requires " & $workCount & " local update(s).",
      choices
    )
    if not response.available:
      return fail(NoTtyError)
    answer = response.answer
  if answer.startsWith("p") and syncCount == 0:
    doRestack = false
  elif workCount > 0 and not answer.startsWith("r"):
    return fail("push aborted.")

  if doRestack:
    # No branch is touched until the worktree is clean and the original branch
    # name or detached commit has been captured for restoration.
    let status = git(["status", "--porcelain", "--untracked-files=normal"])
    if status.status != 0:
      return fail("could not verify that the working tree is clean.")
    if status.output.len > 0:
      return fail("automatic restacking requires a clean working tree.")
    var restore = git(["symbolic-ref", "--quiet", "--short", "HEAD"])
    if restore.status != 0:
      restore = git(["rev-parse", "HEAD"])
    if restore.status != 0:
      return fail("could not preserve the current checkout before restacking.")
    let restoreTarget = restore.output.strip()

    # Print compact recovery references once, before changing any local tip.
    stderr.writeLine("\nLocal branch tips before restacking:")
    for update in updates:
      if update.needsSync:
        stderr.writeLine("  " & update.remoteName & " [" & update.localSha[0 ..< 7] & "]")
    for branch in branchInfo.branches:
      if not branch.stale:
        continue
      var alreadyPrinted = false
      for update in updates:
        if update.needsSync and update.remoteName == branch.name:
          alreadyPrinted = true
      if not alreadyPrinted:
        let tip = if branch.localSha.len > 0: branch.localSha[0 ..< 7] else: "missing"
        stderr.writeLine("  " & branch.name & " [" & tip & "]")
    stderr.writeLine("")

    # First integrate remote commits that appeared during the fetch. The
    # starting snapshot is the exact boundary between remote and local work.
    for i in 0 ..< updates.len:
      if not updates[i].needsSync:
        continue
      stderr.writeLine(updates[i].remoteName & " → replaying local commits onto updated " &
        remote & "/" & updates[i].remoteName)
      let replay = replayCommits(
        updates[i].remoteName, updates[i].fetchedRemoteSha,
        updates[i].syncBaseSha, restoreTarget
      )
      if not replay.ok:
        return 1
      updates[i].localSha = replay.tip
      let index = branchInfo.branches.findBranch(updates[i].remoteName)
      if index >= 0:
        branchInfo.branches[index].futureSha = replay.tip
        branchInfo.branches[index].localSha = replay.tip

    for i in 0 ..< branchInfo.branches.len:
      if not branchInfo.branches[i].needsSync:
        continue
      stderr.writeLine(branchInfo.branches[i].name &
        " → replaying local commits onto updated " & remote & "/" &
        branchInfo.branches[i].name)
      let replay = replayCommits(
        branchInfo.branches[i].name, branchInfo.branches[i].remoteSha,
        branchInfo.branches[i].historySha, restoreTarget
      )
      if not replay.ok:
        return 1
      branchInfo.branches[i].localSha = replay.tip
      branchInfo.branches[i].futureSha = replay.tip

    # Then repair broken parent edges from roots to leaves. A missing local
    # descendant is materialized from its fetched remote tip before rebasing.
    for depth in 0 .. maxDepth:
      for i in 0 ..< branchInfo.branches.len:
        if not branchInfo.branches[i].stale or
            branchInfo.branches[i].depth != depth:
          continue
        let parent = branchInfo.branches[i].parent
        if branchInfo.branches[i].localSha.len == 0:
          stderr.writeLine(branchInfo.branches[i].name & " ← creating local branch from " &
            remote & "/" & branchInfo.branches[i].name)
          if git(["branch", branchInfo.branches[i].name,
              branchInfo.branches[i].remoteSha], parentStreams = true).status != 0:
            return fail("could not create a local branch needed for restacking.")
          branchInfo.branches[i].localSha = branchInfo.branches[i].remoteSha

        let
          parentSha =
            if parent >= 0: branchInfo.branches[parent].futureSha
            else: baseInfo.baseSha
          parentName =
            if parent >= 0: branchInfo.branches[parent].name
            else: baseInfo.name

        # An omitted child may already be correctly restacked locally:
        #
        #   remote: master -- A0 -- B0
        #   local:  master -- A1 -- B1
        #
        # When pushing A1, B1 needs to join the atomic push but not be rebased.
        var alreadyStacked = isAncestor(parentSha, branchInfo.branches[i].localSha)

        # A merge can contain both the rewritten parent and its obsolete
        # history:
        #
        #   master -- A0 -- B0 --.
        #        `-- A1 ---------+-- local B
        #
        # A1 is technically an ancestor, but leaving A0 in B would preserve the
        # broken stack. Force a replay when both histories are still present.
        if alreadyStacked and parent >= 0 and
            not isAncestor(branchInfo.branches[parent].historySha, parentSha) and
            isAncestor(branchInfo.branches[parent].historySha,
              branchInfo.branches[i].localSha):
          alreadyStacked = false
        if alreadyStacked:
          stderr.writeLine(branchInfo.branches[i].name &
            " ✓ already stacked on " & parentName)
          branchInfo.branches[i].futureSha = branchInfo.branches[i].localSha
          continue

        stderr.writeLine(branchInfo.branches[i].name & " → rebasing onto " & parentName)
        let oldParent =
          if parent >= 0: branchInfo.branches[parent].historySha
          else: baseInfo.historyBaseSha
        let replay = replayCommits(
          branchInfo.branches[i].name, parentSha, oldParent, restoreTarget
        )
        if not replay.ok:
          return 1
        branchInfo.branches[i].futureSha = replay.tip
        branchInfo.branches[i].localSha = replay.tip

    # `checkout` accepts either the saved branch name or a detached commit ID.
    if git(["checkout", "--quiet", restoreTarget], parentStreams = true).status != 0:
      return fail("restacked branches but could not restore the original checkout.")

  # Every ref gets an exact post-fetch lease (empty for a new branch). Atomic
  # push ensures a later change to one branch prevents all branches from moving.
  #
  #   leases calculated: A=A1, B=B1
  #   remote races:      A moves to A2
  #   result:            reject both A and B; atomicity leaves B at B1
  var pushArgs = @["push", "--quiet", "--atomic"]
  for branch in branchInfo.branches:
    if doRestack and branch.stale and not branch.pushed:
      pushArgs.add "--force-with-lease=refs/heads/" & branch.name & ":" & branch.remoteSha
  for update in updates:
    pushArgs.add "--force-with-lease=refs/heads/" & update.remoteName & ":" &
      update.fetchedRemoteSha
  pushArgs.add remote
  for branch in branchInfo.branches:
    if doRestack and branch.stale and not branch.pushed:
      pushArgs.add branch.name & ":refs/heads/" & branch.name
  for update in updates:
    pushArgs.add update.remoteName & ":refs/heads/" & update.remoteName

  # Skip only stack-check in the child push; all unrelated hooks still run.
  let hadSkip = existsEnv("STACK_CHECK_SKIP")
  let oldSkip = getEnv("STACK_CHECK_SKIP")
  putEnv("STACK_CHECK_SKIP", "1")
  let pushStatus = git(pushArgs, parentStreams = true).status
  if hadSkip: putEnv("STACK_CHECK_SKIP", oldSkip)
  else: delEnv("STACK_CHECK_SKIP")
  if pushStatus != 0:
    return fail("the stack push failed.")
  if not doRestack and staleCount > 0:
    stderr.writeLine("Pushed requested branches without restacking.")
  else:
    stderr.writeLine((if doRestack: "Restacked" else: "Checked") &
      " and pushed all affected branches.")
  0
