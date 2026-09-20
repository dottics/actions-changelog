# Changelog entries

Every user-visible change gets one file here. Changes are short-lived feature
branches at most, so a change needs exactly one file to record what it did and
how far it moves the version.

```
.changelog/csv-export-endpoint.md
```

The filename is a short slug — it only exists to keep two PRs from colliding.
The file contents become the changelog line.

```markdown
semver: minor
Added a CSV export endpoint at `/api/export`
```

## Choosing the bump and the category

The file starts with a small header:

```
semver: {major|minor|patch}
type: {Added|Changed|Deprecated|Removed|Fixed|Security}
```

`semver:` is **required** — it says whether your change is breaking (`major`),
a backwards-compatible addition (`minor`), or a fix (`patch`). There is no
default; leaving it out fails the build rather than guessing how far the
version should move.

`type:` is optional. It picks the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
heading your entry appears under. Without it the category follows the bump:
`major → Changed`, `minor → Added`, `patch → Fixed`.

```markdown
semver: patch
type: Security
Bumped golang.org/x/net to patch CVE-2026-1234
```

The two header lines can be in either order, and the header ends at the first
line that isn't one of them — so a body that happens to contain a colon is
safe.

## Longer entries

Extra lines are indented under the bullet:

```markdown
semver: major
type: Removed
Dropped the v1 API.

See `docs/migrating-to-v2.md` for the upgrade path.
```

If you write your own bullets, they pass through untouched:

```markdown
semver: minor
- Added `--format json`
- Added `--format yaml`
```

## What happens next

When your PR merges, a bot opens a `chore(release): vX.Y.Z` pull request that
folds every waiting entry into `../../../../CHANGELOG.md`, bumps the version, and deletes
the entry files. The highest `semver:` among the waiting entries wins — one
`major` entry alongside five `patch` entries produces a major release.

## Coming from the old layout?

Entries used to live in `.changelog/major/`, `.changelog/minor/` and
`.changelog/patch/`, with the directory setting the bump. Those directories are
gone. Move each file up one level and add the `semver:` line it implied:

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

A file left behind in one of those directories is an error, not a silent skip —
the release fails and tells you which files to move.
