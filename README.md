# changelog-action

A GitHub Action that keeps `CHANGELOG.md` up to date without anyone having to
remember to edit it.

Contributors drop a small file into `.changelog/` as part of their PR. When
that PR merges, this action works out the next semver version, writes a
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) section, deletes the
consumed entries and opens a `chore(release): vX.Y.Z` pull request. Merging
that PR is the release gate.

Pure bash in a composite action — no build step, no binary, no npm.

## Why entry files instead of parsing commits

Conventional-commit parsing infers the changelog from messages written for
other developers. Entry files make the changelog line an explicit, reviewable
artifact of the PR, and because every PR adds its own file, two PRs never touch
the same one — so there are no merge conflicts on `CHANGELOG.md`.

## How it fits together

```
PR #12  adds .changelog/csv-export.md    ──┐  (semver: minor)
PR #13  adds .changelog/fix-redirect.md  ──┤  (semver: patch)
                                           │   both merge to main
                       push to main ───────┘
                                │
                    changelog-action (mode: release)
                                │
                    opens PR "chore(release): v1.3.0"
                      • CHANGELOG.md gets a [1.3.0] section
                      • VERSION bumped (optional)
                      • entry files deleted
                                │
                          you merge it
                                │
                     tag v1.3.0 and release
```

The action never tags or publishes. It only ever proposes a pull request, so a
human stays in the loop and every version bump is reviewable.

## Using it in another repo

Nothing to install — GitHub fetches the action from this repo at run time.

**1. Create the entry directory:**

```bash
mkdir -p .changelog
curl -sO https://raw.githubusercontent.com/dottics/actions-changelog/main/.changelog/README.md \
  --output-dir .changelog          # contributor docs, optional but recommended
```

**2. Add the release workflow** — copy [`examples/release-pr.yml`](examples/release-pr.yml)
to `.github/workflows/release-pr.yml`. The whole thing is:

```yaml
name: Release PR

on:
  push:
    branches: [main]

concurrency:
  group: release-pr-${{ github.ref }}

permissions:
  contents: write
  pull-requests: write

jobs:
  release-pr:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          fetch-tags: true
      - uses: dottics/actions-changelog@v2
        with:
          mode: release
          base-branch: main
```

**3. Optionally enforce entries on PRs** — copy
[`examples/validate-entries.yml`](examples/validate-entries.yml).

**4. Optionally tag on merge** — copy [`examples/tag-on-merge.yml`](examples/tag-on-merge.yml)
to create the git tag and GitHub Release once the release PR lands. That is the
last piece of the CI/CD loop; this action itself never tags.

**5. Allow Actions to open PRs.** In the consuming repo:
Settings → Actions → General → Workflow permissions → tick
*"Allow GitHub Actions to create and approve pull requests"*.

### Pinning

| Reference | Behaviour |
| --- | --- |
| `dottics/actions-changelog@v2` | Latest v2.x.y. Recommended. |
| `dottics/actions-changelog@v2.0.1` | Exact release. |
| `dottics/actions-changelog@<sha>` | Immutable. Use if you need supply-chain pinning. |

`@v1` still works and still expects the old `.changelog/{major,minor,patch}/`
directories. See [Upgrading from v1](#upgrading-from-v1) before moving the pin.

If the repo is private, consuming repos need
Settings → Actions → General → *Access* set to allow other repos in the
`dottics` org to use it.

## Writing an entry

One flat file per change, `.changelog/csv-export-endpoint.md`:

```markdown
semver: minor
Added a CSV export endpoint at `/api/export`
```

The filename is a slug for uniqueness only. The header says how far the version
moves; everything below it is the changelog line.

`semver:` is required and must be `major`, `minor` or `patch`. A missing or
unrecognised value fails the run — the action will not guess how far to move
the version.

`type:` is optional and picks the Keep a Changelog category:

```markdown
semver: patch
type: Security
Bumped golang.org/x/net to patch CVE-2026-1234
```

Without it the category is derived from the bump: `major → Changed`,
`minor → Added`, `patch → Fixed`. The two header lines may appear in either
order, and the header ends at the first line that isn't one of them. Multi-line
bodies get hanging indentation; bodies you've already written as `- ` bullets
pass through untouched.

Full contributor docs live in [`.changelog/README.md`](.changelog/README.md) —
copy that file into your repo so contributors have the format to hand.

## How the version is calculated

The base version is `max(latest git tag, newest heading in CHANGELOG.md)`,
compared as semver. Using both means the action stays correct whether you tag
before or after merging the release PR, and it recovers if one of the two drifts.

The bump is the **highest level present** across all waiting entries — one
`semver: major` entry alongside five `semver: patch` entries produces a major
bump.

```
tag v1.2.3 + changelog [1.2.3] + a `semver: minor` entry  →  1.3.0
tag v1.2.3 + changelog [1.4.0] + a `semver: major` entry  →  2.0.0
no tags + no changelog + a `semver: patch` entry          →  0.0.1
```

If the computed version already has a section in `CHANGELOG.md`, the action
fails rather than writing a duplicate.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `mode` | `release` | `release` opens the bump PR; `validate` checks entries on a PR. |
| `entry-dir` | `.changelog` | Directory holding the entry files. |
| `changelog-file` | `CHANGELOG.md` | Path to the changelog. Created if missing. |
| `version-file` | *(empty)* | Optional file to write the bare version into, e.g. `VERSION`. |
| `open-api-path` | *(empty)* | OpenAPI contract(s) whose `info.version` follows the release. See [Stamping contracts](#stamping-contracts). |
| `tag-prefix` | `v` | Prefix on release tags. |
| `force-bump` | *(empty)* | Override the detected level (`major`/`minor`/`patch`). |
| `release-date` | today (UTC) | Date used in the section heading. |
| `compare-links` | `true` | Maintain `[x.y.z]: .../compare/...` reference links. |
| `base-branch` | current ref | Branch the release PR targets. |
| `branch-prefix` | `release/` | Release branch name prefix. |
| `pr-title` | `chore(release): <tag>` | Title of the release PR. |
| `pr-labels` | *(empty)* | Comma-separated labels for the release PR. |
| `commit-message` | `chore(release): <tag>` | Commit message on the release branch. |
| `git-user-name` / `git-user-email` | `github-actions[bot]` | Commit identity. |
| `require-entry` | `true` | *(validate)* Fail when a PR adds no entry. |
| `skip-labels` | `no-changelog,skip-changelog` | *(validate)* Labels that waive `require-entry`. |
| `dry-run` | `false` | Do everything except push and open the PR. |
| `token` | `github.token` | Token for pushing and PR creation. |

## Outputs

| Output | Description |
| --- | --- |
| `has-changes` | `true` when entries were found and a release was prepared. |
| `bump` | The bump level applied. |
| `version` | New version, bare (`1.4.0`). |
| `previous-version` | Version the bump was calculated from. |
| `tag` | New version with the tag prefix (`v1.4.0`). |
| `pull-request-url` | URL of the opened or updated release PR. |
| `entry-count` | Number of entry files seen. |
| `stamped-files` | Newline-separated list of contract files the version was written into. |

## Stamping contracts

The release PR can carry the new version into your API contracts, so the
published spec never disagrees with the changelog.

```yaml
- uses: dottics/actions-changelog@v2
  with:
    mode: release
    open-api-path: api/openapi.yaml
```

The value is repo-relative and accepts several paths, comma- or
newline-separated, with globs:

```yaml
    open-api-path: api/openapi.yaml, api/admin.yaml
    open-api-path: services/*/openapi.yaml
    open-api-path: |
      api/public/openapi.yaml
      api/internal/openapi.json
```

Both YAML and JSON specs are supported. Only `info.version` is touched — the
rewrite is line- and character-scoped, so comments, key order, indentation,
quote style and every other `version` key in the file survive untouched:

```diff
 openapi: 3.1.0
 info:
   title: Widget API
   # Managed by dottics/actions-changelog — do not edit by hand.
-  version: 1.2.3
+  version: 1.3.0
```

It fails loudly rather than guessing. A path that matches nothing, a spec with
no `info.version`, or an `info:` written in flow style (`info: {…}`) all stop
the run before a PR is opened.

### Adding another contract type

`scripts/stamp.sh` is a small registry. A new format is three edits:

1. Write `stamp_<format>()` in `scripts/stamp.sh`, format-preserving.
2. Add a `case` arm to `stamp_file`.
3. Add the input to `action.yml` and a line to `STAMP_SPECS` in `scripts/release.sh`:

```bash
STAMP_SPECS=(
  "openapi|$OPEN_API_PATH"
  "asyncapi|$ASYNC_API_PATH"     # <- new
)
```

Path expansion, glob handling, missing-file errors, the PR body listing and
the `stamped-files` output all come for free.

## Things worth knowing

**Checkout needs history and tags.** Use `fetch-depth: 0` and `fetch-tags: true`,
otherwise the action can't see the latest tag and will compute the wrong base.

**Permissions.** The release job needs `contents: write` and `pull-requests: write`.

**PRs opened with `GITHUB_TOKEN` don't trigger other workflows.** That's a
GitHub safeguard against recursion. If your release PR needs CI to run on it,
pass a PAT or GitHub App token via the `token` input.

**Re-running is safe.** The release branch is recreated and force-pushed with
`--force-with-lease`, and an existing open PR is updated in place rather than
duplicated. So if two PRs merge in quick succession, the second run just
refreshes the same release PR with both entries.

**The action does not tag.** Tagging on merge of the release PR is a separate
one-liner; keeping it out means this action can never publish something you
didn't approve.

**Nothing nested is collected.** Entries are flat files directly in the entry
directory. A file in a subdirectory is an error, not a silent skip, so a change
can never go unreleased because it landed in the wrong place.

## Upgrading from v1

In v1 the bump came from the directory an entry lived in. In v2 it comes from a
`semver:` header in the file, and the entry directory is flat.

```diff
- .changelog/minor/csv-export.md
-     Added a CSV export endpoint at `/api/export`
+ .changelog/csv-export.md
+     semver: minor
+     Added a CSV export endpoint at `/api/export`
```

To migrate a repo, move each waiting entry up a level and prepend the line its
directory implied:

```bash
for level in major minor patch; do
  for f in .changelog/$level/*.md; do
    [ -e "$f" ] || continue
    { echo "semver: $level"; cat "$f"; } > ".changelog/$(basename "$f")"
    git rm -q "$f"
    git add ".changelog/$(basename "$f")"
  done
done
rm -rf .changelog/{major,minor,patch}
```

Then move the pin from `@v1` to `@v2`. Already-released `CHANGELOG.md` sections
are untouched — the change is only in how pending entries are written.

If you bump the pin before migrating, the run fails with the list of files to
move rather than opening an empty release PR.

## Repo layout

```
action.yml               composite action definition
scripts/lib.sh           semver, entry header parsing, changelog rendering
scripts/stamp.sh         contract version stampers (openapi; extend here)
scripts/validate.sh      mode: validate
scripts/release.sh       mode: release — rewrites CHANGELOG.md in the worktree
scripts/open-pr.sh       branch, commit, push, gh pr create/edit
tests/run.sh             dependency-free bash test suite
examples/                workflows to copy into consuming repos
```

## Releasing this action

Tag a `vX.Y.Z` release; `.github/workflows/major-tag.yml` force-moves the
floating `vX` tag so consumers on `@v2` pick it up automatically. This repo
dogfoods its own `.changelog` directory, so the version bump itself arrives as
a release PR.

## Development

```bash
tests/run.sh          # unit tests, no dependencies beyond bash + git + coreutils
shellcheck -x -P scripts scripts/*.sh tests/run.sh
```

To try a release end to end without touching GitHub, run the scripts directly
in a scratch repo:

```bash
ENTRY_DIR=.changelog REPO_URL=https://github.com/acme/widget \
  scripts/release.sh
VERSION=1.3.0 BUMP=minor DRY_RUN=true scripts/open-pr.sh
```

## License

MIT
