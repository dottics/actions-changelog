#!/usr/bin/env bash
# Plain-bash test suite. No dependencies beyond git, coreutils and bash 4+.
# Usage: tests/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib.sh
. "$ROOT/scripts/lib.sh"
# shellcheck source=../scripts/stamp.sh
. "$ROOT/scripts/stamp.sh"

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
mkdir -p "$E"
printf 'semver: minor\nAdded CSV export endpoint at /api/export\n'                        >"$E/export.md"
printf 'semver: patch\ntype: Fixed\nLogin redirect loop on expired sessions\n'            >"$E/redirect.md"
printf -- 'semver: patch\n- First bullet\n- Second bullet\n'                              >"$E/bullets.md"
printf 'semver: major\ntype: Removed\nDropped the v1 API.\n\nSee the migration guide.\n'   >"$E/dropv1.md"
printf 'semver: major\nA prose entry with no type header\n'                                >"$E/plain.md"
printf 'type: Security\nsemver: patch\nHeader order does not matter\n'                     >"$E/reversed.md"
printf 'README placeholder\n' >"$E/README.md"

check 'entries_find count' '6' "$(entries_find "$E" | wc -l | tr -d ' ')"
check 'entries_find ignores README' '0' "$(entries_find "$E" | grep -c 'README.md')"
check 'entries_find ignores dotfiles' '0' \
  "$(: >"$E/.gitkeep"; entries_find "$E" | grep -c '.gitkeep')"

mkdir -p "$E/major" "$E/notes"
printf 'semver: patch\nLeft over from v1\n' >"$E/major/old.md"
printf 'scratch\n' >"$E/notes/todo.md"
check 'entries_find does not recurse' '0' "$(entries_find "$E" | grep -c '/major/\|/notes/')"
check 'nested files reported' "$E/major/old.md
$E/notes/todo.md" "$(entries_nested "$E")"
legacy() { if entry_is_legacy "$1" "$E"; then printf 'yes'; else printf 'no'; fi; }
check 'v1 bump dir recognised as legacy' 'yes' "$(legacy "$E/major/old.md")"
check 'other subdir is not legacy'       'no'  "$(legacy "$E/notes/todo.md")"
rm -rf "$E/major" "$E/notes"

# --- header block -----------------------------------------------------------
check 'semver from header'          'minor'  "$(entry_semver "$E/export.md")"
check 'semver with type above it'   'patch'  "$(entry_semver "$E/reversed.md")"
check 'semver missing -> empty'     ''       "$(printf 'no header here\n' >"$E/bare.md"; entry_semver "$E/bare.md")"
check 'semver invalid -> empty'     ''       "$(printf 'semver: huge\nx\n' >"$E/huge.md"; entry_semver "$E/huge.md")"
check 'raw semver survives invalid' 'huge'   "$(entry_raw_semver "$E/huge.md")"
check 'normalize_bump uppercase'    'major'  "$(normalize_bump MAJOR)"
check 'normalize_bump unknown'      ''       "$(normalize_bump breaking)"
check 'header stops at first non-header line' '1' "$(entry_header_lines "$E/export.md")"
check 'header counts both keys'     '2'      "$(entry_header_lines "$E/redirect.md")"
check 'no header -> zero lines'     '0'      "$(entry_header_lines "$E/bare.md")"
check 'multi-word colon line is body not header' '1' \
  "$(printf 'semver: patch\ntype: string fields are now trimmed\n' >"$E/colon.md"
     entry_header_lines "$E/colon.md")"
check 'that body line survives' 'type: string fields are now trimmed' "$(entry_body "$E/colon.md")"
rm -f "$E/bare.md" "$E/huge.md" "$E/colon.md" "$E/.gitkeep"

check 'type from header'   'Fixed'    "$(entry_type "$E/redirect.md")"
check 'type default minor' 'Added'    "$(entry_type "$E/export.md")"
check 'type default major' 'Changed'  "$(entry_type "$E/plain.md")"
check 'type default patch' 'Fixed'    "$(entry_type "$E/bullets.md")"
check 'declared beats default' 'Removed'  "$(entry_type "$E/dropv1.md")"
check 'type read below semver' 'Security' "$(entry_type "$E/reversed.md")"
check 'normalize lowercase' 'Security' "$(normalize_type security)"
check 'normalize unknown'   ''         "$(normalize_type nonsense)"

check 'body strips whole header' 'Login redirect loop on expired sessions' "$(entry_body "$E/redirect.md")"
check 'render prose'    '- Added CSV export endpoint at /api/export' "$(entry_render "$E/export.md")"
check 'render bullets passthrough' '- First bullet
- Second bullet' "$(entry_render "$E/bullets.md")"
check 'render multiline hangs' '- Dropped the v1 API.

  See the migration guide.' "$(entry_render "$E/dropv1.md")"

# ---------------------------------------------------------------------------
section 'section rendering'
# ---------------------------------------------------------------------------
LIST="$WORK/list"; entries_find "$E" >"$LIST"
SEC="$(render_section 2.0.0 2026-08-09 "$LIST")"
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
- Login redirect loop on expired sessions

### Security

- Header order does not matter'
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

# ---------------------------------------------------------------------------
section 'openapi stamping'
# ---------------------------------------------------------------------------
API="$WORK/api"; mkdir -p "$API"
cat >"$API/spec.yaml" <<'YAML'
openapi: 3.1.0
info:
  title: Widget API
  # managed automatically
  version: 1.2.3   # trailing comment
  description: |
    Prose that says version: 9.9.9 and must not change.
  contact:
    name: Platform
    version: not-this-one
paths:
  /w:
    get:
      responses:
        '200':
          content:
            application/json:
              schema:
                properties:
                  version: {type: string}
x-meta:
  version: leave-me
YAML
stamp_openapi "$API/spec.yaml" 2.0.0 2>/dev/null
check 'yaml: info.version updated'      '  version: 2.0.0   # trailing comment' "$(sed -n '5p' "$API/spec.yaml")"
check 'yaml: comment line preserved'    '  # managed automatically' "$(sed -n '4p' "$API/spec.yaml")"
check 'yaml: prose untouched'           '1' "$(grep -c 'version: 9.9.9' "$API/spec.yaml")"
check 'yaml: contact.version untouched' '1' "$(grep -c 'version: not-this-one' "$API/spec.yaml")"
check 'yaml: schema property untouched' '1' "$(grep -c 'version: {type: string}' "$API/spec.yaml")"
check 'yaml: other top-level untouched' '1' "$(grep -c 'version: leave-me' "$API/spec.yaml")"
check 'yaml: exactly one 2.0.0'         '1' "$(grep -c '2\.0\.0' "$API/spec.yaml")"

printf "openapi: 3.1.0\ninfo:\n  version: '1.0.0'\n  title: X\n" >"$API/q.yaml"
stamp_openapi "$API/q.yaml" 2.0.0 2>/dev/null
check 'yaml: single-quote style kept' "  version: '2.0.0'" "$(sed -n '3p' "$API/q.yaml")"
printf 'openapi: 3.1.0\ninfo:\n    title: X\n    version: "1.0.0"\n' >"$API/i4.yaml"
stamp_openapi "$API/i4.yaml" 2.0.0 2>/dev/null
check 'yaml: 4-space indent + double quotes' '    version: "2.0.0"' "$(sed -n '4p' "$API/i4.yaml")"

cat >"$API/spec.json" <<'JSON'
{
  "openapi": "3.1.0",
  "info": {
    "title": "Widget API",
    "description": "mentions \"version\": \"0.0.0\" in a string",
    "version": "1.2.3",
    "contact": { "name": "P", "version": "nope" }
  },
  "components": { "schemas": { "X": { "properties": { "version": { "type": "string" } } } } }
}
JSON
stamp_openapi "$API/spec.json" 2.0.0 2>/dev/null
check 'json: info.version updated'      '    "version": "2.0.0",' "$(sed -n '6p' "$API/spec.json")"
check 'json: escaped string untouched'  '1' "$(grep -c '0\.0\.0' "$API/spec.json")"
check 'json: contact.version untouched' '1' "$(grep -c '"version": "nope"' "$API/spec.json")"
check 'json: exactly one 2.0.0'         '1' "$(grep -c '2\.0\.0' "$API/spec.json")"

printf '{"openapi":"3.1.0","info":{"title":"M","version":"1.0.0"},"paths":{}}' >"$API/min.json"
stamp_openapi "$API/min.json" 2.0.0 2>/dev/null
check 'json: minified handled' '{"openapi":"3.1.0","info":{"title":"M","version":"2.0.0"},"paths":{}}' \
  "$(cat "$API/min.json")"

fails() { if ( "$@" ) >/dev/null 2>&1; then printf 'no'; else printf 'yes'; fi; }
printf 'openapi: 3.1.0\ninfo:\n  title: X\n' >"$API/noversion.yaml"
printf 'openapi: 3.1.0\ninfo: {title: X, version: 1.0.0}\n' >"$API/flow.yaml"
printf '{"openapi":"3.1.0","paths":{}}\n' >"$API/noversion.json"
check 'yaml: missing info.version fails' 'yes' "$(fails stamp_openapi "$API/noversion.yaml" 2.0.0)"
check 'yaml: flow-style info fails'      'yes' "$(fails stamp_openapi "$API/flow.yaml" 2.0.0)"
check 'json: missing info.version fails' 'yes' "$(fails stamp_openapi "$API/noversion.json" 2.0.0)"
check 'missing file fails'               'yes' "$(fails stamp_file openapi "$API/ghost.yaml" 2.0.0)"
check 'unknown format fails'             'yes' "$(fails stamp_file asyncapi "$API/spec.yaml" 2.0.0)"
check 'stamping is idempotent'           'no'  "$(fails stamp_openapi "$API/spec.yaml" 2.0.0)"

check 'expand: comma + glob keeps last item' "$API/min.json
$API/noversion.json
$API/spec.json
$API/spec.yaml" "$(stamp_expand "$API/*.json, $API/spec.yaml" 'openapi path')"
check 'expand: newline separated' "$API/spec.yaml
$API/q.yaml" "$(stamp_expand "$(printf '%s\n%s' "$API/spec.yaml" "$API/q.yaml")" 'openapi path')"
check 'expand: unmatched glob fails' 'yes' "$(fails stamp_expand "$API/*.toml" 'openapi path')"
check 'expand: unmatched literal fails' 'yes' "$(fails stamp_expand "$API/ghost.yaml" 'openapi path')"

# ---------------------------------------------------------------------------
section 'release.sh / validate.sh end to end'
# ---------------------------------------------------------------------------
mkrepo() {
  local d="$1"
  mkdir -p "$d/.changelog"
  (
    cd "$d" || exit 1
    git init --quiet -b main
    git config user.email t@t.t; git config user.name t
    printf 'x\n' >f; git add f; git commit --quiet -m init
    git tag v1.2.3
  )
}
run_release()  { ( cd "$1" && ENTRY_DIR=.changelog "$ROOT/scripts/release.sh" ); }
run_validate() { ( cd "$1" && ENTRY_DIR=.changelog REQUIRE_ENTRY=false "$ROOT/scripts/validate.sh" ); }

R1="$WORK/e2e-ok"; mkrepo "$R1"
printf 'semver: minor\ntype: Added\nA brand new endpoint\n' >"$R1/.changelog/endpoint.md"
printf 'semver: patch\nFixed a typo\n'                      >"$R1/.changelog/typo.md"
( cd "$R1" && git add .changelog && git commit --quiet -m entries )
out="$( cd "$R1" && ENTRY_DIR=.changelog CHANGELOG_FILE=CHANGELOG.md \
        RELEASE_DATE=2026-08-09 REPO_URL=https://github.com/acme/w \
        "$ROOT/scripts/release.sh" 2>&1 )"
check 'e2e: highest bump wins'   'version=1.3.0' "$(printf '%s\n' "$out" | grep '^version=')"
check 'e2e: base from git tag'   'previous-version=1.2.3' "$(printf '%s\n' "$out" | grep '^previous-version=')"
check 'e2e: entry count'         'entry-count=2' "$(printf '%s\n' "$out" | grep '^entry-count=')"
exists() { if [ -e "$1" ]; then printf 'yes'; else printf 'no'; fi; }
check 'e2e: entries consumed'    '0'   "$(entries_find "$R1/.changelog" | wc -l | tr -d ' ')"
check 'e2e: entry dir survives'  'yes' "$(exists "$R1/.changelog")"
check 'e2e: no bump dirs remade' 'no'  "$(exists "$R1/.changelog/patch")"
check 'e2e: section written'     '1' "$(grep -c '^## \[1\.3\.0\]' "$R1/CHANGELOG.md")"
check 'e2e: declared category'   '1' "$(grep -c '^### Added' "$R1/CHANGELOG.md")"
check 'e2e: derived category'    '1' "$(grep -c '^### Fixed' "$R1/CHANGELOG.md")"

R2="$WORK/e2e-nosemver"; mkrepo "$R2"
printf 'A line with no header at all\n' >"$R2/.changelog/oops.md"
check 'e2e: missing semver stops the release' 'yes' "$(fails run_release "$R2")"
check 'e2e: changelog untouched on failure'   'no'  "$(exists "$R2/CHANGELOG.md")"
printf 'semver: enormous\nx\n' >"$R2/.changelog/oops.md"
check 'e2e: invalid semver stops the release' 'yes' "$(fails run_release "$R2")"

R3="$WORK/e2e-legacy"; mkrepo "$R3"
mkdir -p "$R3/.changelog/minor"
printf 'An entry left in the v1 layout\n' >"$R3/.changelog/minor/old.md"
check 'e2e: v1 layout fails instead of releasing nothing' 'yes' "$(fails run_release "$R3")"

V="$WORK/e2e-validate"; mkdir -p "$V/.changelog"
printf 'semver: patch\nPerfectly fine\n' >"$V/.changelog/fine.md"
check 'e2e: validate accepts a good entry' 'no' "$(fails run_validate "$V")"
printf 'semver: patch\ntype: Bogus\nx\n' >"$V/.changelog/bad-type.md"
check 'e2e: validate rejects an unknown type' 'yes' "$(fails run_validate "$V")"
rm -f "$V/.changelog/bad-type.md"
printf 'semver: patch\n' >"$V/.changelog/no-body.md"
check 'e2e: validate rejects an empty body' 'yes' "$(fails run_validate "$V")"
rm -f "$V/.changelog/no-body.md"
printf 'Body but no semver\n' >"$V/.changelog/no-semver.md"
check 'e2e: validate rejects a missing semver' 'yes' "$(fails run_validate "$V")"
rm -f "$V/.changelog/no-semver.md"
mkdir -p "$V/.changelog/patch"
printf 'semver: patch\nx\n' >"$V/.changelog/patch/nested.md"
check 'e2e: validate rejects the v1 layout' 'yes' "$(fails run_validate "$V")"
rm -rf "$V/.changelog/patch"
check 'e2e: validate green again once fixed' 'no' "$(fails run_validate "$V")"

printf '%s\n' '--------------------------------------------'
if [ "$FAIL" -eq 0 ]; then
  green "all $PASS checks passed"
else
  red "$FAIL failed, $PASS passed"
  exit 1
fi
