---
description: "Release a new NMC version — bump version, update changelog, commit, tag, and push"
allowed-tools: ["Read", "Edit", "Bash", "Grep", "Glob"]
---

# NMC: Release

Release a new version of No More Configs. This command handles the full release flow: version bump, changelog update, commit, tag, and push. The GitHub Actions workflows then auto-create the GitHub release and publish to npm.

## Step 1: Determine the new version

Parse `$ARGUMENTS` for a version hint:
- If a semver is given (e.g. `1.3.0`), use it directly
- If `major`, `minor`, or `patch` is given, bump accordingly from the current version
- If empty, default to `patch`

Read the current version from `/workspace/cli/package.json` (the `.version` field). This is the npm package version and the single source of truth.

## Step 2: Check for unreleased changes

Run `git log` from the latest tag to HEAD to confirm there are commits to release. If there are no new commits, inform the user and stop.

Show the user:
- Current version → new version
- Commits being released (one-line format)
- Files changed since last tag

Ask the user to confirm before proceeding.

## Step 3: Bump version

Edit `/workspace/cli/package.json` to update the `"version"` field to the new version.

## Step 4: Update CHANGELOG.md

Read `/workspace/CHANGELOG.md`. Insert a new section after the `---` that follows the format header, **before** the previous release entry. The new section should:

- Use heading `## [X.Y.Z] - YYYY-MM-DD` with today's date
- Summarize the commits being released, grouped by type using Keep a Changelog categories:
  - **Added** — new features
  - **Changed** — changes to existing functionality
  - **Fixed** — bug fixes
  - **Removed** — removed features
- Only include categories that have entries
- Update the comparison links at the bottom of the file:
  - Add `[X.Y.Z]: https://github.com/agomusio/no-more-configs/compare/vPREVIOUS...HEAD`
  - Update the previous version's link to compare against the new tag instead of HEAD

## Step 5: Update cli/README.md (if needed)

Check if any changes affect the CLI installer's README (e.g. new prerequisites, usage changes). If so, update `/workspace/cli/README.md`. This file is published to npm as the package README.

## Step 6: Commit, tag, and push

Stage all changed files and create a commit:

```
chore: bump version to vX.Y.Z
```

Then:
1. Create a tag: `git tag vX.Y.Z`
2. Push commit and tag: `git push origin main --tags`

## Step 7: Confirm release

After pushing, inform the user:

```
## Released vX.Y.Z

- Commit: <short-hash>
- Tag: vX.Y.Z pushed to origin
- GitHub release: auto-created by `.github/workflows/release.yml`
- npm publish: auto-published by `.github/workflows/publish-npm.yml`

Track workflows: https://github.com/agomusio/no-more-configs/actions
```

---

## Files that change during a release

| File | What changes |
|------|-------------|
| `cli/package.json` | `"version"` field bumped — single source of truth for the version |
| `CHANGELOG.md` | New version section added, comparison links updated |
| `cli/README.md` | Only if release includes changes relevant to the npm installer (prerequisites, usage, etc.) |

## Release pipeline reference

A `v*` tag push triggers two independent GitHub Actions workflows in parallel:

1. **`release.yml`** (Create Release) — extracts the matching version section from `CHANGELOG.md` (using awk), writes it to a temp file, and creates a GitHub release via `gh release create --notes-file`. Uses `GITHUB_TOKEN` for auth.

2. **`publish-npm.yml`** (Publish to npm) — runs `npm publish --provenance --access public` from the `cli/` directory. Auth is handled by **OIDC trusted publishing** (GitHub Actions proves identity directly to npm via `id-token: write` permission). No `NPM_TOKEN` secret is needed. The npm package `no-more-configs` is configured on npmjs.com to trust this specific workflow file.

### Key details

- **Both workflows trigger on tag push** — they do NOT chain (`release.yml` does not trigger `publish-npm.yml`). This is because `GITHUB_TOKEN`-created events don't trigger downstream workflows.
- **OIDC trust is file-specific** — npm is configured to trust `publish-npm.yml` by name. Do not rename this file or move the publish step to another workflow without updating the trusted publishing config on npmjs.com.
- **Changelog formatting matters** — `release.yml` extracts notes using awk between `## [version]` headings. Avoid backtick-heavy content in the first line after the heading (it gets passed through bash). The `--notes-file` approach prevents shell interpretation issues.
- **`cli/` is the npm package root** — only `cli/package.json`, `cli/index.js`, and `cli/README.md` are published (per the `"files"` field in package.json).
