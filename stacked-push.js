#!/usr/bin/env -S fnm exec --using=default node

const fs = require('node:fs');
const path = require('node:path');
const {
  DEFAULT_RELEASE_BRANCHES,
  discoverStackGraph,
  git,
  gitOk,
  gitOutput,
  unique,
} = require('./stacked.js');

const isInteractive = process.stdout.isTTY;
const colors = isInteractive ? {
  green: '\x1b[1;32m',
  yellow: '\x1b[1;33m',
  red: '\x1b[1;31m',
  lightWhite: '\x1b[37m',
  boldWhite: '\x1b[1;97m',
  reset: '\x1b[0m',
} : {
  green: '',
  yellow: '',
  red: '',
  lightWhite: '',
  boldWhite: '',
  reset: '',
};

const ZERO_OID = '0000000000000000000000000000000000000000';
const DEFAULT_STACK_BASE_BRANCH = 'master';
const REMOTE_URL_PATTERN = /^(https?:\/\/|ssh:\/\/|git@|\/|file:\/\/|\.{1,2}\/)/;

function print(message = '', stream = process.stdout) {
  stream.write(`${message}\n`);
}

function warn(message) {
  print(`${colors.yellow}Warning:${colors.reset} ${message}`, process.stderr);
}

function fail(message) {
  print(`${colors.red}Error:${colors.reset} ${message}`, process.stderr);
  process.exit(1);
}

function normalizePushTarget(localRef) {
  if (localRef === 'HEAD') {
    return git(['symbolic-ref', '--quiet', '--short', 'HEAD'], { check: false }).stdout.trim();
  }
  return localRef.replace(/^refs\/heads\//, '');
}

function readHookPushTargetsFromStdin() {
  if (process.stdin.isTTY) return [];
  const input = fs.readFileSync(0, 'utf8');
  return unique(input
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => line.split(/\s+/))
    // Git pre-push feeds one ref update per line on stdin.
    .filter(([localRef, localSha]) => (localRef === 'HEAD' || localRef?.startsWith('refs/heads/')) && localSha && localSha !== ZERO_OID)
    .map(([localRef]) => normalizePushTarget(localRef)));
}

function parseArgs(argv) {
  let doFetch = true;
  const cliArgs = [];

  for (const arg of argv) {
    if (arg === '--no-fetch') {
      doFetch = false;
    } else if (arg === '--fetch') {
      doFetch = true;
    } else if (arg === '--help' || arg === '-h') {
      print(`Usage: ${path.basename(__filename)} [remote] [remote-url] [branch ...] [--no-fetch]

Env:
  STACKED_BRANCHES_SKIP=1
  STACKED_BRANCHES_BASE_BRANCH=master
  STACKED_BRANCHES_RELEASE_BRANCHES="dev test release master main"`);
      process.exit(0);
    } else {
      cliArgs.push(arg);
    }
  }

  return { doFetch, cliArgs };
}

function resolveRemoteAndTargets(cliArgs) {
  const releaseBranches = (process.env.STACKED_BRANCHES_RELEASE_BRANCHES || DEFAULT_RELEASE_BRANCHES.join(' '))
    .split(/\s+/)
    .filter(Boolean);
  let remote = 'origin';
  const args = [...cliArgs];

  if (args.length > 0 && gitOk(['config', '--get', `remote.${args[0]}.url`])) {
    remote = args.shift();
  } else if (args.length > 0 && REMOTE_URL_PATTERN.test(args[0])) {
    remote = args.shift();
  }

  if (args.length > 0 && REMOTE_URL_PATTERN.test(args[0])) {
    args.shift();
  }

  let pushTargets = args.length > 0 ? args.map(normalizePushTarget) : readHookPushTargetsFromStdin();

  if (pushTargets.length === 0) {
    const currentBranch = gitOutput(['symbolic-ref', '--quiet', '--short', 'HEAD']);
    if (!currentBranch) fail('unable to determine the branch being pushed.');
    pushTargets = [currentBranch];
  }

  return {
    remote,
    releaseBranches,
    pushTargets: unique(pushTargets).filter((branch) => !releaseBranches.includes(branch)),
  };
}

function buildStackGraph(remote, pushTargets, releaseBranches) {
  const stackBaseBranch = process.env.STACKED_BRANCHES_BASE_BRANCH || DEFAULT_STACK_BASE_BRANCH;
  const baseRef = `refs/remotes/${remote}/${stackBaseBranch}`;

  if (!gitOk(['show-ref', '--verify', '--quiet', baseRef])) {
    fail(`base branch ${stackBaseBranch} has no ${remote}/${stackBaseBranch} remote ref.`);
  }

  const graph = discoverStackGraph({
    remote,
    base: stackBaseBranch,
    baseRef,
    seeds: pushTargets,
    excludedBranches: releaseBranches,
  });
  graph.unresolved.forEach((branch) => warn(`Skipping stack detection for ${branch} because it could not be resolved locally or on ${remote}.`));

  const branches = new Map();
  for (const branch of graph.branches) {
    const localRef = gitOk(['show-ref', '--verify', '--quiet', `refs/heads/${branch}`]) ? `refs/heads/${branch}` : '';
    const remoteRef = gitOk(['show-ref', '--verify', '--quiet', `refs/remotes/${remote}/${branch}`]) ? `refs/remotes/${remote}/${branch}` : '';
    const parent = graph.parents.get(branch);
    branches.set(branch, {
      branch,
      localRef,
      remoteRef,
      parent: parent === stackBaseBranch ? '' : parent,
      children: [],
      depth: graph.depths.get(branch),
    });
  }

  for (const meta of branches.values()) {
    if (meta.parent) branches.get(meta.parent)?.children.push(meta.branch);
  }

  return branches;
}

function collectDescendants(branches, root, includeRoot = false) {
  const pending = [root];
  const descendants = [];

  while (pending.length > 0) {
    const current = pending.shift();
    if (includeRoot || current !== root) descendants.push(current);
    for (const child of branches.get(current)?.children || []) pending.push(child);
  }

  return descendants;
}

function collectDrift(branches, pushTargets) {
  const pushTargetSet = new Set(pushTargets);
  const staleBranches = new Set();

  for (const branch of pushTargets) {
    const meta = branches.get(branch);
    if (!meta) {
      warn(`Skipping ${branch} because it is not present in the discovered stack graph.`);
      continue;
    }

    const descendants = collectDescendants(branches, branch);

    if (!meta.localRef) {
      warn(`Skipping local drift checks for ${branch} because no local branch exists yet.`);
      continue;
    }

    if (meta.remoteRef) {
      const localSha = gitOutput(['rev-parse', meta.localRef]);
      const remoteSha = gitOutput(['rev-parse', meta.remoteRef]);
      if (localSha !== remoteSha) {
        for (const stale of descendants) {
          const descendant = branches.get(stale);
          if (pushTargetSet.has(stale) && descendant?.localRef && gitOk(['merge-base', '--is-ancestor', meta.localRef, descendant.localRef])) {
            continue;
          }
          staleBranches.add(stale);
        }
      }
    } else {
      warn(`Skipping origin drift check for ${branch} because ${branch} does not exist.`);
    }

    if (!meta.parent) continue;
    const parent = branches.get(meta.parent);
    if (!parent) {
      warn(`Skipping parent drift check for ${branch} because its inferred parent could not be indexed.`);
      continue;
    }
    const parentRef = parent.localRef || parent.remoteRef;
    if (!parentRef) {
      warn(`Skipping parent drift check for ${branch} because its inferred parent has no local or remote ref.`);
      continue;
    }
    if (!gitOk(['merge-base', '--is-ancestor', parentRef, meta.localRef])) {
      for (const stale of collectDescendants(branches, branch, true)) staleBranches.add(stale);
    }
  }

  return [...staleBranches];
}

function promptAction() {
  if (!isInteractive || !fs.existsSync('/dev/tty')) {
    fail('non-interactive session with drift detected.');
  }

  const fd = fs.openSync('/dev/tty', 'r+');
  const buffer = Buffer.alloc(1024);
  try {
    fs.writeSync(fd, `\n${colors.boldWhite}Rebase stacked branches now?${colors.reset}\n`);
    fs.writeSync(fd, `  ${colors.green}[y]${colors.reset} rebase and update the stack\n`);
    fs.writeSync(fd, `  ${colors.yellow}[n]${colors.reset} leave branches unchanged ${colors.lightWhite}(default)${colors.reset}\n\n`);
    fs.writeSync(fd, 'Rebase [y/N]: ');

    let reply = '';
    while (true) {
      const bytesRead = fs.readSync(fd, buffer, 0, buffer.length, null);
      if (bytesRead <= 0) break;
      reply += buffer.toString('utf8', 0, bytesRead);
      if (reply.includes('\n') || reply.includes('\r')) break;
    }

    fs.writeSync(fd, '\n');
    return reply.trim().toLowerCase();
  } finally {
    fs.closeSync(fd);
  }
}

function renderDriftReport(branches, staleBranches) {
  if (staleBranches.length === 0) {
    print(`${colors.green}Stacked branch check passed.${colors.reset}`);
    return [];
  }

  const rebaseOrder = staleBranches
    .map((branch) => branches.get(branch))
    .filter(Boolean)
    .sort((a, b) => a.depth - b.depth || a.branch.localeCompare(b.branch));

  print(`\n${colors.yellow}You may need to rebase following stacked branches:${colors.reset}`);
  for (const meta of rebaseOrder) {
    print(`${colors.yellow}•${colors.reset} Rebase ${colors.green}${meta.branch}${colors.reset} to ${colors.green}${meta.parent}${colors.reset}`);
  }
  print();

  return rebaseOrder;
}

function runStackedPush(branches, rebaseOrder, pushTargets, remote) {
  if (rebaseOrder.length > 0) {
    if (gitOutput(['status', '--porcelain', '--untracked-files=normal'])) {
      fail('automatic rebases require a clean working tree.');
    }

    const currentBranch = git(['symbolic-ref', '--quiet', '--short', 'HEAD'], { check: false }).stdout.trim();
    const restoreTarget = currentBranch || gitOutput(['rev-parse', 'HEAD']);
    let rebaseError;
    try {
      // Rebase shallow-to-deep so each child lands on an already-restacked parent.
      for (const meta of rebaseOrder) {
        if (!meta.localRef && meta.remoteRef) {
          print(`${colors.yellow}Creating local branch ${meta.branch} from ${meta.remoteRef}...${colors.reset}`);
          if (git(['branch', meta.branch, meta.remoteRef], { check: false, stdio: 'inherit' }).status !== 0) {
            throw new Error(`failed to create local branch ${meta.branch} from ${meta.remoteRef}.`);
          }
          meta.localRef = `refs/heads/${meta.branch}`;
        }

        const parent = branches.get(meta.parent);
        const rebaseTarget = parent?.localRef || parent?.remoteRef || meta.parent;
        print(`${colors.yellow}Rebasing ${meta.branch} onto ${rebaseTarget}...${colors.reset}`);
        if (git(['rebase', rebaseTarget, meta.branch], { check: false, stdio: 'inherit' }).status !== 0) {
          git(['rebase', '--abort'], { check: false, stdio: 'ignore' });
          throw new Error(`Rebase failed for ${meta.branch}. Rolled back the failed rebase and blocked the operation.`);
        }
      }
    } catch (error) {
      rebaseError = error;
    }

    if (git(['checkout', '-q', restoreTarget], { check: false, stdio: 'inherit' }).status !== 0) {
      if (rebaseError) throw new Error(`${rebaseError.message} Additionally, failed to restore original checkout ${restoreTarget}.`);
      throw new Error(`Failed to restore original checkout ${restoreTarget}.`);
    }
    if (rebaseError) throw rebaseError;
  }

  const branchesToPush = unique([
    ...rebaseOrder.map(({ branch }) => branch),
    ...pushTargets,
  ]);
  if (branchesToPush.length > 0) {
    print(`${colors.yellow}Pushing ${branchesToPush.join(', ')} to ${remote}...${colors.reset}`);
    const result = git(['push', '--force-with-lease', '--no-verify', remote, ...branchesToPush], {
      check: false,
      env: { ...process.env, STACKED_BRANCHES_SKIP: '1' },
      stdio: 'inherit',
    });
    if (result.status !== 0) throw new Error('Failed to push stacked branches.');
  }

  print(`${colors.green}Stacked push completed.${colors.reset}`);
}

function main() {
  if (process.env.STACKED_BRANCHES_SKIP === '1') {
    print(`${colors.yellow}Skipping stacked branch check.${colors.reset}`);
    return;
  }

  const repoRoot = git(['rev-parse', '--show-toplevel'], { check: false }).stdout.trim();
  if (!repoRoot) fail(`could not locate a git repo from ${process.cwd()}.`);
  process.chdir(repoRoot);

  const { doFetch, cliArgs } = parseArgs(process.argv.slice(2));
  const { remote, releaseBranches, pushTargets } = resolveRemoteAndTargets(cliArgs);

  if (doFetch) {
    print(`${colors.yellow}Fetching ${remote}...${colors.reset}`);
    const result = git(['fetch', '--quiet', remote], {
      check: false,
      env: { ...process.env, GIT_TERMINAL_PROMPT: '0' },
      stdio: 'inherit',
    });
    if (result.status !== 0) fail(`failed to fetch ${remote}.`);
  } else {
    print(`${colors.yellow}Skipping fetch for ${remote}.${colors.reset}`);
  }

  if (pushTargets.length === 0) {
    print(`${colors.yellow}Skipping stacked branch check for release-only push.${colors.reset}`);
    return;
  }

  const branches = buildStackGraph(remote, pushTargets, releaseBranches);
  const rebaseOrder = renderDriftReport(branches, collectDrift(branches, pushTargets));

  let rebaseOrderToApply = rebaseOrder;
  if (rebaseOrder.length > 0) {
    const action = promptAction();
    if (!['y', 'yes', 'r', 'rebase'].includes(action)) {
      print(`${colors.yellow}Leaving stacked branches unchanged.${colors.reset}`);
      rebaseOrderToApply = [];
    }
  }

  runStackedPush(branches, rebaseOrderToApply, pushTargets, remote);
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    fail(error.message);
  }
}
