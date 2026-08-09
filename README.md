# changelog-action

A GitHub Action that keeps `CHANGELOG.md` up to date without anyone having to
remember to edit it.

Contributors drop a small file into `.changelog/{major,minor,patch}/` as part
of their PR. When that PR merges, this action works out the next semver
version, writes a [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
section, deletes the consumed entries and opens a `chore(release): vX.Y.Z`
pull request. Merging that PR is the release gate.

Pure bash in a composite action — no build step, no binary, no npm.

## Why entry files instead of parsing commits

Conventional-commit parsing infers the changelog from messages written for
other developers. Entry files make the changelog line an explicit, reviewable
artifact of the PR, and the per-bump-level directories mean two PRs never touch
the same file, so there are no merge conflicts on `CHANGELOG.md`.

## How it fits together

```
PR #12  adds .changelog/minor/csv-export.md   ──┐
PR #13  adds .changelog/patch/fix-redirect.md ──┤  both merge to main
                                                 │
                        push to main ────────────┘
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

## Setup

**1. Create the entry directory** in your repo:

```
.changelog/
  README.md          # copy the one from this repo — it's the contributor docs
  major/.gitkeep
  minor/.gitkeep
  patch/.gitkeep
```

**2. Add the release workflow** — copy [`examples/release-pr.yml`](examples/release-pr.yml)
to `.github/workflows/release-pr.yml`.

**3. Optionally add the validation workflow** — copy
[`examples/validate-entries.yml`](examples/validate-entries.yml) to enforce
"every PR ships a changelog entry".

## Writing an entry

`.changelog/minor/csv-export-endpoint.md`:

```markdown
Added a CSV export endpoint at `/api/export`
```

The directory sets the bump level. The filename is a slug for uniqueness only.
The body is the changelog line.

To pick a specific Keep a Changelog category, add a `type:` first line:

```markdown
type: Security
Bumped golang.org/x/net to patch CVE-2026-1234
```

Without one, the category is derived from the bump level: `major → Changed`,
`minor → Added`, `patch → Fixed`. Multi-line bodies get hanging indentation;
bodies you've already written as `- ` bullets pass through untouched.

Full contributor docs live in [`.changelog/README.md`](.changelog/README.md).

## How the version is calculated

The base version is `max(latest git tag, newest heading in CHANGELOG.md)`,
compared as semver. Using both means the action stays correct whether you tag
before or after merging the release PR, and it recovers if one of the two drifts.

The bump is the **highest level present** across all waiting entries — one
`major/` entry alongside five `patch/` entries produces a major bump.

```
tag v1.2.3 + changelog [1.2.3] + a minor/ entry   →  1.3.0
tag v1.2.3 + changelog [1.4.0] + a major/ entry   →  2.0.0
no tags + no changelog + a patch/ entry           →  0.0.1
```

If the computed version already has a section in `CHANGELOG.md`, the action
fails rather than writing a duplicate.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `mode` | `release` | `release` opens the bump PR; `validate` checks entries on a PR. |
| `entry-dir` | `.changelog` | Directory holding `major/ minor/ patch/`. |
| `changelog-file` | `CHANGELOG.md` | Path to the changelog. Created if missing. |
| `version-file` | *(empty)* | Optional file to write the bare version into, e.g. `VERSION`. |
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

## Repo layout

```
action.yml               composite action definition
scripts/lib.sh           semver, entry parsing, changelog rendering
scripts/validate.sh      mode: validate
scripts/release.sh       mode: release — rewrites CHANGELOG.md in the worktree
scripts/open-pr.sh       branch, commit, push, gh pr create/edit
tests/run.sh             dependency-free bash test suite
examples/                workflows to copy into consuming repos
```

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
