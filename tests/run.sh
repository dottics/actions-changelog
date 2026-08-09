#!/usr/bin/env bash
# Plain-bash test suite. No dependencies beyond git, coreutils and bash 4+.
# Usage: tests/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib.sh
. "$ROOT/scripts/lib.sh"

PASS=0; FAIL=0
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); green "  ok   $1"
  else
    FAIL=$((FAIL + 1)); red "  FAIL $1"
    printf '       expected: %q\n' "$2"
    printf '       actual:   %q\n' "$3"
  fi
}

section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
section 'semver'
# ---------------------------------------------------------------------------
check 'bump patch'            '1.2.4'  "$(semver_bump 1.2.3 patch)"
check 'bump minor resets patch' '1.3.0' "$(semver_bump 1.2.3 minor)"
check 'bump major resets rest'  '2.0.0' "$(semver_bump 1.2.3 major)"
check 'bump strips v prefix'    '2.0.0' "$(semver_bump v1.9.9 major)"
check 'max picks numeric order' '1.10.0' "$(semver_max 1.9.0 1.10.0)"
check 'max handles v prefix'    '2.0.1'  "$(semver_max v2.0.1 1.99.99)"
check 'max with empty args'     '0.0.0'  "$(semver_max '' '')"
check 'max with one empty'      '0.3.0'  "$(semver_max '' v0.3.0)"
accepts() { if semver_valid "$1"; then printf 'yes'; else printf 'no'; fi; }
check 'valid 1.2.3'   'yes' "$(accepts 1.2.3)"
check 'valid v1.2.3'  'yes' "$(accepts v1.2.3)"
check 'invalid 1.2'   'no'  "$(accepts 1.2)"
check 'invalid 1.2.3-rc1' 'no' "$(accepts 1.2.3-rc1)"
check 'rank ordering' '1 2 3' "$(bump_rank patch) $(bump_rank minor) $(bump_rank major)"

# ---------------------------------------------------------------------------
section 'entry parsing'
# ---------------------------------------------------------------------------
E="$WORK/entries"
mkdir -p "$E"/{major,minor,patch}
printf 'Added CSV export endpoint at /api/export\n' >"$E/minor/export.md"
printf 'type: Fixed\nLogin redirect loop on expired sessions\n' >"$E/patch/redirect.md"
printf -- '- First bullet\n- Second bullet\n' >"$E/patch/bullets.md"
printf 'type: Removed\nDropped the v1 API.\n\nSee the migration guide.\n' >"$E/major/dropv1.md"
printf 'A prose entry with no type header\n' >"$E/major/plain.md"
printf 'README placeholder\n' >"$E/README.md"

check 'entries_find count' '5' "$(entries_find "$E" | wc -l | tr -d ' ')"
check 'entries_find ignores README' '0' "$(entries_find "$E" | grep -c 'README.md')"
check 'entries_find ignores top-level files' '0' \
  "$(printf 'oops\n' >"$E/oops.md"; entries_find "$E" | grep -c 'oops.md')"
check 'stray file detected' "$E/oops.md" "$(entries_stray "$E")"
check 'stray check ignores README' '0' "$(entries_stray "$E" | grep -c 'README.md')"
rm -f "$E/oops.md"

mkdir -p "$E/hotfix"
check 'bad dir detected' "$E/hotfix" "$(entries_bad_dirs "$E")"
rmdir "$E/hotfix"

check 'type from header'   'Fixed'   "$(entry_type "$E/patch/redirect.md" patch)"
check 'type default minor' 'Added'   "$(entry_type "$E/minor/export.md" minor)"
check 'type default major' 'Changed' "$(entry_type "$E/major/plain.md" major)"
check 'type default patch' 'Fixed'   "$(entry_type "$E/patch/bullets.md" patch)"
check 'declared beats default' 'Removed' "$(entry_type "$E/major/dropv1.md" major)"
check 'normalize lowercase' 'Security' "$(normalize_type security)"
check 'normalize unknown'   ''         "$(normalize_type nonsense)"

check 'body strips header' 'Login redirect loop on expired sessions' "$(entry_body "$E/patch/redirect.md")"
check 'render prose'    '- Added CSV export endpoint at /api/export' "$(entry_render "$E/minor/export.md")"
check 'render bullets passthrough' '- First bullet
- Second bullet' "$(entry_render "$E/patch/bullets.md")"
check 'render multiline hangs' '- Dropped the v1 API.

  See the migration guide.' "$(entry_render "$E/major/dropv1.md")"

# ---------------------------------------------------------------------------
section 'section rendering'
# ---------------------------------------------------------------------------
TSV="$WORK/tsv"; entries_find "$E" >"$TSV"
SEC="$(render_section 2.0.0 2026-08-09 "$TSV")"
expected='## [2.0.0] - 2026-08-09

### Added

- Added CSV export endpoint at /api/export

### Changed

- A prose entry with no type header

### Removed

- Dropped the v1 API.

  See the migration guide.

### Fixed

- First bullet
- Second bullet
- Login redirect loop on expired sessions'
check 'section groups by category in KaC order' "$expected" "$SEC"

# ---------------------------------------------------------------------------
section 'changelog insertion'
# ---------------------------------------------------------------------------
CL="$WORK/CHANGELOG.md"
changelog_ensure "$CL"
S1="$WORK/s1"; printf '## [0.1.0] - 2026-01-01\n\n### Added\n\n- First release\n\n' >"$S1"
changelog_insert "$CL" "$S1"
check 'preamble survives, release goes below it' 'preamble<release' \
  "$(pre=$(grep -n '^All notable' "$CL" | cut -d: -f1)
     rel=$(grep -n '^## \[0.1.0\]' "$CL" | cut -d: -f1)
     [ -n "$pre" ] && [ -n "$rel" ] && [ "$pre" -lt "$rel" ] && echo 'preamble<release')"
check 'heading detected after insert' '0.1.0' "$(version_from_changelog "$CL")"

S2="$WORK/s2"; printf '## [0.2.0] - 2026-02-01\n\n### Added\n\n- Second release\n\n' >"$S2"
changelog_insert "$CL" "$S2"
check 'newest heading is on top' '0.2.0' "$(version_from_changelog "$CL")"
check 'both releases present' '2' "$(grep -cE '^## \[' "$CL")"
check 'exactly one blank line before newest' '1' \
  "$(awk '/^## \[0\.2\.0\]/{print blank; exit} /^$/{blank++; next} {blank=0}' "$CL")"

# ---------------------------------------------------------------------------
section 'compare links'
# ---------------------------------------------------------------------------
URL='https://github.com/acme/widget'
changelog_update_links "$CL" 0.1.0 '' "$URL" v
changelog_update_links "$CL" 0.2.0 0.1.0 "$URL" v
check 'first release links to tag' "[0.1.0]: $URL/releases/tag/v0.1.0" \
  "$(grep -F '[0.1.0]:' "$CL")"
check 'later release links to compare' "[0.2.0]: $URL/compare/v0.1.0...v0.2.0" \
  "$(grep -F '[0.2.0]:' "$CL")"
check 'newest link ref on top of block' '[0.2.0]' \
  "$(grep -E '^\[[0-9]' "$CL" | head -1 | cut -d: -f1)"
changelog_update_links "$CL" 0.2.0 0.1.0 "$URL" v
check 'link refs are not duplicated' '1' "$(grep -cF '[0.2.0]:' "$CL")"

S3="$WORK/s3"; printf '## [0.3.0] - 2026-03-01\n\n### Fixed\n\n- Third\n\n' >"$S3"
changelog_insert "$CL" "$S3"
check 'insert still lands above releases, not in link block' '0.3.0' \
  "$(version_from_changelog "$CL")"
check 'link block stays at the bottom' '[0.2.0]' \
  "$(grep -E '^\[[0-9]' "$CL" | head -1 | cut -d: -f1)"

# changelog with no releases but an existing link block
CL2="$WORK/CHANGELOG2.md"
printf '# Changelog\n\nPreamble.\n\n[unreleased]: https://example.com/x\n' >"$CL2"
changelog_insert "$CL2" "$S1"
check 'insert above a pre-existing link block' '3' \
  "$(grep -n '^## \[0.1.0\]' "$CL2" | cut -d: -f1 | head -1 | xargs -I{} sh -c 'test {} -lt 6 && echo 3 || echo {}')"

# ---------------------------------------------------------------------------
section 'version discovery from git tags'
# ---------------------------------------------------------------------------
REPO="$WORK/repo"; mkdir -p "$REPO"
(
  cd "$REPO" || exit 1
  git init --quiet -b main
  git config user.email t@t.t; git config user.name t
  printf 'x\n' >f; git add f; git commit --quiet -m init
  git tag v0.9.0; git tag v0.10.0; git tag v0.10.0-rc1 2>/dev/null || true; git tag nightly
)
check 'highest tag by semver order' '0.10.0' "$(cd "$REPO" && version_from_tags v)"
check 'no tags -> empty' '' "$(cd "$WORK" && version_from_tags zzz)"

printf '%s\n' '--------------------------------------------'
if [ "$FAIL" -eq 0 ]; then
  green "all $PASS checks passed"
else
  red "$FAIL failed, $PASS passed"
  exit 1
fi
