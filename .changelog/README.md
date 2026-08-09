# Changelog entries

Every user-visible change gets a file here. Put it in the directory matching
the semver bump your change requires:

```
.changelog/
  major/   # breaking change
  minor/   # new functionality, backwards compatible
  patch/   # bug fix or internal change worth mentioning
```

The filename is a short slug — it only exists to keep two PRs from colliding.
The file contents become the changelog line.

```
.changelog/minor/csv-export-endpoint.md
```

```markdown
Added a CSV export endpoint at `/api/export`
```

## Choosing the category

By default the Keep a Changelog category is derived from the bump level:
`major → Changed`, `minor → Added`, `patch → Fixed`. To say otherwise, put a
`type:` line at the very top:

```markdown
type: Security
Bumped golang.org/x/net to patch CVE-2026-1234
```

Valid types: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.

## Longer entries

Extra lines are indented under the bullet:

```markdown
type: Removed
Dropped the v1 API.

See `docs/migrating-to-v2.md` for the upgrade path.
```

If you write your own bullets, they pass through untouched:

```markdown
- Added `--format json`
- Added `--format yaml`
```

## What happens next

When your PR merges, a bot opens a `chore(release): vX.Y.Z` pull request that
folds every waiting entry into `CHANGELOG.md`, bumps the version, and deletes
the entry files. The highest bump level among the entries wins.
