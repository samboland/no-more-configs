#!/usr/bin/env node

// No More Configs — npx installer & updater
// https://github.com/samboland/no-more-configs
// Zero dependencies. Single file. ESM.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { resolve, basename } from "node:path";

// ---------------------------------------------------------------------------
// ANSI helpers — respects NO_COLOR (https://no-color.org) and dumb terminals
// ---------------------------------------------------------------------------

const colorEnabled =
  !process.env.NO_COLOR &&
  process.env.TERM !== "dumb" &&
  process.stdout.isTTY;

const esc = (code) => (colorEnabled ? `\x1b[${code}m` : "");

const c = {
  reset: esc(0),
  bold: esc(1),
  dim: esc(2),
  green: esc(32),
  yellow: esc(33),
  cyan: esc(36),
  red: esc(31),
};

// ---------------------------------------------------------------------------
// Custom error for git failures
// ---------------------------------------------------------------------------

class GitError extends Error {
  constructor(message, stderr) {
    super(message);
    this.name = "GitError";
    this.stderr = stderr;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function git(args, cwd) {
  try {
    return execFileSync("git", args, {
      cwd,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (err) {
    const stderr = err.stderr?.trim() || err.message;
    throw new GitError(`git ${args[0]} failed`, stderr);
  }
}

function hasGit() {
  try {
    execFileSync("git", ["--version"], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

function tryOpenVSCode(dir) {
  try {
    execFileSync("code", [dir], { stdio: "pipe", timeout: 5000 });
    return true;
  } catch {
    return false;
  }
}

function readVersionFromChangelog(dir) {
  try {
    const changelog = readFileSync(resolve(dir, "CHANGELOG.md"), "utf8");
    const match = changelog.match(/^## \[(\d+\.\d+\.\d+)\]/m);
    return match ? match[1] : null;
  } catch {
    return null;
  }
}

/** Check if a directory is an NMC clone. */
function isNmcRepo(dir) {
  // Primary: check git remote URL
  try {
    const remote = git(["config", "--get", "remote.origin.url"], dir);
    if (remote.includes("no-more-configs")) return true;
  } catch {
    // not a git repo or no remote — fall through
  }

  // Fallback: check for NMC-specific files
  return (
    existsSync(resolve(dir, ".devcontainer", "install-agent-config.sh")) &&
    existsSync(resolve(dir, "agent-config"))
  );
}

/** Detect if we are running inside a devcontainer. */
function isInsideContainer() {
  return (
    existsSync("/.dockerenv") ||
    !!process.env.REMOTE_CONTAINERS ||
    !!process.env.CODESPACES
  );
}

/**
 * Files that NMC users are expected to modify — changes to these should NOT
 * trigger a dirty-tree warning during updates.
 */
const USER_FILES = ["config.json", "secrets.json", "projects/"];

function hasTrackedChanges(dir) {
  try {
    const status = git(["status", "--porcelain"], dir);
    if (!status) return false;

    // Filter out user-owned files
    const lines = status.split("\n").filter((line) => {
      const file = line.slice(3); // strip status columns
      return !USER_FILES.some(
        (uf) => file === uf || file.startsWith(uf)
      );
    });
    return lines.length > 0;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// --help / --version
// ---------------------------------------------------------------------------

const HELP = `
${c.bold}No More Configs${c.reset} — installer & updater

${c.bold}Usage:${c.reset}
  npx no-more-configs [directory]   Install or update NMC
  npx no-more-configs --help        Show this help
  npx no-more-configs --version     Show version

${c.bold}Arguments:${c.reset}
  directory   Target directory (default: ${c.cyan}no-more-configs${c.reset})

${c.bold}Fresh install:${c.reset}
  Clones the repo, prints next steps, and tries to open VS Code.

${c.bold}Update:${c.reset}
  Pulls latest changes. If devcontainer files changed, advises rebuild.

${c.bold}More info:${c.reset} https://github.com/samboland/no-more-configs
`.trim();

function printHelp() {
  console.log(HELP);
}

function printVersion() {
  try {
    const pkg = JSON.parse(
      readFileSync(new URL("./package.json", import.meta.url), "utf8")
    );
    console.log(pkg.version);
  } catch {
    console.log("unknown");
  }
}

// ---------------------------------------------------------------------------
// Fresh install
// ---------------------------------------------------------------------------

function freshInstall(targetDir) {
  const dirName = basename(targetDir);

  console.log(
    `\n${c.cyan}${c.bold}No More Configs${c.reset} — installing into ${c.bold}${dirName}/${c.reset}\n`
  );

  // 1. Check git
  if (!hasGit()) {
    console.error(
      `${c.red}Error:${c.reset} git is not installed. Install it from https://git-scm.com/`
    );
    process.exit(1);
  }

  // 2. Clone
  console.log(`${c.dim}Cloning repository...${c.reset}`);
  try {
    git(
      [
        "clone",
        "https://github.com/samboland/no-more-configs.git",
        targetDir,
      ],
      process.cwd()
    );
  } catch (err) {
    console.error(`${c.red}Clone failed:${c.reset} ${err.stderr}`);
    process.exit(1);
  }

  // 3. Read version
  const version = readVersionFromChangelog(targetDir) || "unknown";

  // 4. Try opening VS Code
  const opened = tryOpenVSCode(targetDir);

  // 5. Summary
  console.log(`\n${c.green}${c.bold}Done!${c.reset} No More Configs ${c.bold}v${version}${c.reset} cloned into ${c.bold}${dirName}/${c.reset}\n`);

  if (opened) {
    console.log(
      `${c.cyan}VS Code opened.${c.reset} When prompted, click ${c.bold}Reopen in Container${c.reset}.`
    );
  } else {
    console.log(`${c.bold}Next steps:${c.reset}`);
    console.log(`  cd ${dirName}`);
    console.log(`  code .`);
    console.log(
      `\nThen click ${c.bold}Reopen in Container${c.reset} when VS Code prompts you.`
    );
  }

  console.log(
    `\nFirst build takes a few minutes. See the README for setup details.`
  );
}

// ---------------------------------------------------------------------------
// Update
// ---------------------------------------------------------------------------

function update(targetDir) {
  const dirName = basename(targetDir);

  console.log(
    `\n${c.cyan}${c.bold}No More Configs${c.reset} — updating ${c.bold}${dirName}/${c.reset}\n`
  );

  const oldVersion = readVersionFromChangelog(targetDir) || "unknown";

  // 1. Save .devcontainer tree hash before pull
  let oldDevcontainerHash = null;
  try {
    oldDevcontainerHash = git(
      ["rev-parse", "HEAD:.devcontainer"],
      targetDir
    );
  } catch {
    // .devcontainer might not exist in tree — unlikely but handle gracefully
  }

  // 2. Fetch
  console.log(`${c.dim}Fetching updates...${c.reset}`);
  try {
    git(["fetch", "origin"], targetDir);
  } catch (err) {
    console.error(`${c.red}Fetch failed:${c.reset} ${err.stderr}`);
    process.exit(1);
  }

  // 3. Check if already up to date
  try {
    const local = git(["rev-parse", "HEAD"], targetDir);
    const remote = git(["rev-parse", "origin/main"], targetDir);
    if (local === remote) {
      console.log(
        `${c.green}Already up to date.${c.reset} (v${oldVersion})`
      );
      return;
    }
  } catch {
    // If comparison fails, continue with pull anyway
  }

  // 4. Warn about dirty working tree (but don't abort)
  if (hasTrackedChanges(targetDir)) {
    console.log(
      `${c.yellow}Warning:${c.reset} You have uncommitted changes to tracked NMC files.`
    );
    console.log(
      `${c.dim}The pull may fail if there are conflicts. Commit or stash first if needed.${c.reset}\n`
    );
  }

  // 5. Pull
  console.log(`${c.dim}Pulling changes...${c.reset}`);
  try {
    git(["pull", "origin", "main"], targetDir);
  } catch (err) {
    console.error(`${c.red}Pull failed:${c.reset} ${err.stderr}`);
    console.log(
      `\n${c.yellow}Tip:${c.reset} If you have local changes, try: git -C ${dirName} stash && npx no-more-configs ${dirName}`
    );
    process.exit(1);
  }

  const newVersion = readVersionFromChangelog(targetDir) || "unknown";

  // 6. Compare .devcontainer tree hash
  let rebuildNeeded = false;
  if (oldDevcontainerHash) {
    try {
      const newDevcontainerHash = git(
        ["rev-parse", "HEAD:.devcontainer"],
        targetDir
      );
      rebuildNeeded = oldDevcontainerHash !== newDevcontainerHash;
    } catch {
      rebuildNeeded = true; // can't compare — assume rebuild needed
    }
  }

  // 7. Summary
  if (oldVersion !== newVersion) {
    console.log(
      `\n${c.green}${c.bold}Updated!${c.reset} v${oldVersion} → ${c.bold}v${newVersion}${c.reset}`
    );
  } else {
    console.log(`\n${c.green}${c.bold}Updated!${c.reset} (v${newVersion})`);
  }

  if (rebuildNeeded) {
    console.log(
      `\n${c.yellow}${c.bold}Container rebuild needed${c.reset} — devcontainer files changed.`
    );

    if (isInsideContainer()) {
      console.log(
        `\n${c.bold}Rebuild from inside VS Code:${c.reset}`
      );
      console.log(
        `  Ctrl+Shift+P → ${c.cyan}Dev Containers: Rebuild Container${c.reset}`
      );
    } else {
      console.log(`\n${c.bold}To apply changes:${c.reset}`);
      console.log(`  1. Open VS Code: ${c.cyan}code ${dirName}${c.reset}`);
      console.log(
        `  2. Ctrl+Shift+P → ${c.cyan}Dev Containers: Rebuild and Reopen in Container${c.reset}`
      );
    }
  } else {
    console.log(`${c.dim}No devcontainer changes — no rebuild needed.${c.reset}`);
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function main() {
  const args = process.argv.slice(2);

  // Flags
  if (args.includes("--help") || args.includes("-h")) {
    printHelp();
    process.exit(0);
  }

  if (args.includes("--version") || args.includes("-v")) {
    printVersion();
    process.exit(0);
  }

  // Target directory — first non-flag argument, default "no-more-configs"
  const positional = args.filter((a) => !a.startsWith("-"));
  const targetDir = resolve(positional[0] || "no-more-configs");

  // Route: update or fresh install
  if (existsSync(targetDir) && isNmcRepo(targetDir)) {
    update(targetDir);
  } else if (existsSync(targetDir)) {
    console.error(
      `${c.red}Error:${c.reset} ${c.bold}${basename(targetDir)}/${c.reset} exists but is not a No More Configs repo.`
    );
    console.log(
      `Choose a different directory name: ${c.cyan}npx no-more-configs my-nmc${c.reset}`
    );
    process.exit(1);
  } else {
    freshInstall(targetDir);
  }
}

main();
