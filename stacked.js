#!/usr/bin/env -S fnm exec --using=default node

const { spawnSync } = require('node:child_process');

const DEFAULT_RELEASE_BRANCHES = ['dev', 'test', 'release', 'master', 'main'];
const MERGE_BRANCH_PATTERNS = [
  /^Merge remote-tracking branch '((refs\/)?remotes\/)?[^/]+\/([^']+)'.*/,
  /^Merge remote-tracking branch '([^']+)'.*/,
  /^Merge branch '([^']+)'.*/,
  /^Merge pull request #[0-9]+ from [^/]+\/(.+)/,
];

const colors = process.stdout.isTTY ? {
  yellow: '\x1b[1;33m',
  red: '\x1b[1;31m',
  bold: '\x1b[1;97m',
  reset: '\x1b[0m',
} : { yellow: '', red: '', bold: '', reset: '' };

function print(message = '', stream = process.stdout) {
  stream.write(`${message}\n`);
}

function fail(message) {
  print(`${colors.red}Error:${colors.reset} ${message}`, process.stderr);
  process.exit(1);
}

function git(args, { check = true, ...options } = {}) {
  const result = spawnSync('git', args, { encoding: 'utf8', ...options });
  if (check && result.status !== 0) {
    throw new Error((result.stderr || '').trim() || `git ${args.join(' ')} failed`);
  }
  return result;
}

function gitOutput(args) {
  return git(args).stdout.trim();
}

function gitOk(args) {
  return git(args, { check: false }).status === 0;
}

function unique(values) {
  return [...new Set(values.filter(Boolean))];
}

function parseArgs(argv) {
  const options = { remote: 'origin', base: 'master', target: '', doFetch: true, branches: [] };
  const valueOptions = { '-t': 'target', '--target': 'target', '--base': 'base', '--remote': 'remote' };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const equalsIndex = arg.indexOf('=');
    const flag = equalsIndex < 0 ? arg : arg.slice(0, equalsIndex);
    const option = valueOptions[flag];

    if (option) {
      const value = equalsIndex < 0 ? argv[++index] : arg.slice(equalsIndex + 1);
      if (!value || value.startsWith('-')) fail(`please specify a value after ${flag}`);
      options[option] = value;
    } else if (arg === '--no-fetch') {
      options.doFetch = false;
    } else if (arg === '-h' || arg === '--help') {
      print(`Usage: stacked.js [options] [BRANCH...]
       stacked.js [options] --target TARGET

Prints direct stack relationships involving the supplied seed branches.
Related remote ancestors and descendants are included automatically.
When no branch is supplied, the current branch is used.
The nearest branch whose tip is an ancestor of another branch is treated as
that branch's direct parent.

Options:
  -t, --target TARGET  collect branches merged into TARGET, then analyze them
      --base BRANCH    base branch shown for stack roots (default: master)
      --remote NAME    remote to fetch and inspect (default: origin)
      --no-fetch       do not fetch before analyzing
  -h, --help           show this help`);
      process.exit(0);
    } else if (arg.startsWith('-')) {
      fail(`unknown option: ${arg}`);
    } else {
      options.branches.push(arg);
    }
  }

  options.branches = options.branches.map((branch) => branch.startsWith(`${options.remote}/`) ? branch.slice(options.remote.length + 1) : branch);
  return options;
}

function branchRef(branch, remote) {
  const normalized = branch.startsWith(`${remote}/`) ? branch.slice(remote.length + 1) : branch;
  const remoteRef = `refs/remotes/${remote}/${normalized}`;
  const localRef = `refs/heads/${normalized}`;
  if (gitOk(['show-ref', '--verify', '--quiet', remoteRef])) return remoteRef;
  if (gitOk(['show-ref', '--verify', '--quiet', localRef])) return localRef;
  return '';
}

function mergeBranchName(subject) {
  for (const pattern of MERGE_BRANCH_PATTERNS) {
    const match = subject.match(pattern);
    if (match) return match[3] || match[1];
  }
  return subject.trim();
}

function discoverStackGraph({ remote = 'origin', base = 'master', baseRef = branchRef(base, remote), seeds, excludedBranches = DEFAULT_RELEASE_BRANCHES }) {
  const excluded = new Set(excludedBranches);
  const refs = new Map();
  const branches = [];
  const unresolved = [];

  for (const branch of unique(seeds)) {
    const ref = branchRef(branch, remote);
    if (!ref) {
      unresolved.push(branch);
      continue;
    }
    branches.push(branch);
    refs.set(branch, ref);
  }

  for (const seed of branches) {
    for (const relation of ['--contains', '--merged']) {
      const related = gitOutput([
        'for-each-ref',
        '--format=%(refname:strip=3)',
        `${relation}=${refs.get(seed)}`,
        `--no-merged=${baseRef}`,
        `refs/remotes/${remote}`,
      ]).split('\n').filter(Boolean);

      for (const branch of related) {
        if (branch === 'HEAD' || refs.has(branch) || excluded.has(branch)) continue;
        branches.push(branch);
        refs.set(branch, `refs/remotes/${remote}/${branch}`);
      }
    }
  }

  const parents = new Map();
  for (const branch of branches) {
    let parent = base;
    let bestDistance = Number.POSITIVE_INFINITY;
    for (const candidate of branches) {
      if (candidate === branch || !gitOk(['merge-base', '--is-ancestor', refs.get(candidate), refs.get(branch)])) continue;
      const distance = Number(gitOutput(['rev-list', '--count', `${refs.get(candidate)}..${refs.get(branch)}`]));
      if (distance > 0 && distance < bestDistance) {
        parent = candidate;
        bestDistance = distance;
      }
    }
    parents.set(branch, parent);
  }

  const depths = new Map();
  for (const branch of branches) {
    let current = branch;
    let depth = 0;
    while (parents.get(current) && parents.get(current) !== base) {
      current = parents.get(current);
      depth += 1;
    }
    depths.set(branch, depth);
  }
  branches.sort((left, right) => depths.get(left) - depths.get(right) || left.localeCompare(right));

  return { branches, depths, parents, unresolved };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const repoRoot = git(['rev-parse', '--show-toplevel'], { check: false }).stdout.trim();
  if (!repoRoot) fail('run this inside a git repository');
  process.chdir(repoRoot);

  if (options.doFetch) {
    print(`${colors.yellow}Fetching ${options.remote}...${colors.reset}`, process.stderr);
    if (git(['fetch', '--quiet', options.remote], { check: false }).status !== 0) fail(`failed to fetch ${options.remote}`);
  }

  const baseRef = branchRef(options.base, options.remote);
  if (!baseRef) fail(`could not resolve base branch ${options.base}`);

  if (options.target) {
    if (options.branches.length > 0) fail('do not combine --target with explicit branches');
    const targetRef = branchRef(options.target, options.remote);
    if (!targetRef) fail(`could not resolve target branch ${options.target}`);
    options.branches = unique(gitOutput(['log', '--format=%s', '--merges', '--reverse', `${baseRef}..${targetRef}`])
      .split('\n')
      .map(mergeBranchName));
    print(`${colors.bold}Branches merged to ${options.target}:${colors.reset}`, process.stderr);
    options.branches.forEach((branch) => print(`  ${branch}`, process.stderr));
  }

  if (!options.target && options.branches.length === 0) {
    const currentBranch = git(['symbolic-ref', '--quiet', '--short', 'HEAD'], { check: false }).stdout.trim();
    if (!currentBranch) fail('could not determine the current branch from a detached HEAD');
    options.branches = [currentBranch];
  }

  if (options.branches.length === 0) {
    if (options.target) print(`No merge branches found in ${options.target}.`);
    return;
  }

  const { branches, parents, unresolved } = discoverStackGraph({
    remote: options.remote,
    base: options.base,
    baseRef,
    seeds: options.branches,
  });
  unresolved.forEach((branch) => print(`${colors.yellow}Warning:${colors.reset} skipping ${branch} because it could not be resolved locally or on ${options.remote}`, process.stderr));
  if (branches.length === 0) fail('none of the requested branches could be resolved');

  print(`\n${colors.bold}Stack relationships:${colors.reset}`);
  branches.forEach((branch) => print(`  ${branch} is stacked on ${parents.get(branch)}`));

  print(`\n${colors.bold}Rebase order:${colors.reset}`);
  branches.forEach((branch) => print(`git rebase ${parents.get(branch)} ${branch}`));

  print(`\n${colors.bold}Push after rebase:${colors.reset}`);
  print(`git push ${options.remote} ${branches.join(' ')} --force-with-lease`);
}

module.exports = { DEFAULT_RELEASE_BRANCHES, discoverStackGraph, git, gitOk, gitOutput, unique };

if (require.main === module) {
  try {
    main();
  } catch (error) {
    fail(error.message);
  }
}
