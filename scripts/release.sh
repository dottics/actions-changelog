#!/usr/bin/env bash
# release.sh — consume the flat .changelog entries, bump the version and rewrite
# CHANGELOG.md in the working tree. Does not commit, branch or push; that is
# open-pr.sh's job.
#
# Env:
#   ENTRY_DIR       default .changelog
#   CHANGELOG_FILE  default CHANGELOG.md
#   VERSION_FILE    optional path to write the bare version into
#   TAG_PREFIX      default v
#   REPO_URL        e.g. https://github.com/owner/repo (enables compare links)
#   RELEASE_DATE    default today (UTC)
#   FORCE_BUMP      major|minor|patch to override what the entries say
#   OPEN_API_PATH   OpenAPI contract(s) whose info.version follows the release;
#                   comma- or newline-separated, globs allowed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=stamp.sh
. "$SCRIPT_DIR/stamp.sh"

ENTRY_DIR="${ENTRY_DIR:-.changelog}"
CHANGELOG_FILE="${CHANGELOG_FILE:-CHANGELOG.md}"
VERSION_FILE="${VERSION_FILE:-}"
TAG_PREFIX="${TAG_PREFIX:-v}"
REPO_URL="${REPO_URL:-}"
RELEASE_DATE="${RELEASE_DATE:-$(date -u +%Y-%m-%d)}"
FORCE_BUMP="${FORCE_BUMP:-}"
SECTION_OUT="${SECTION_OUT:-}"
OPEN_API_PATH="${OPEN_API_PATH:-}"

# Contract/manifest stamping targets: "<format>|<path spec>".
# Register a new contract type by adding one line here and one stamper in
# scripts/stamp.sh.
STAMP_SPECS=(
  "openapi|$OPEN_API_PATH"
)

# --- gather entries ---------------------------------------------------------

# Nested files are never collected, so a leftover v1 `major/ minor/ patch/`
# tree would quietly release nothing at all. Stop before that can happen.
nested="$(entries_nested "$ENTRY_DIR")"
if [ -n "$nested" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if entry_is_legacy "$f" "$ENTRY_DIR"; then
      warn "$f uses the v1 bump-level layout."
    else
      warn "$f is in a subdirectory of $ENTRY_DIR/ and is not a changelog entry."
    fi
  done <<<"$nested"
  die "entries must be flat files ($ENTRY_DIR/<short-slug>.md) with a 'semver:' header. Move the files listed above and re-run."
fi

list="$(mktemp)"
entries_find "$ENTRY_DIR" >"$list"

if [ ! -s "$list" ]; then
  log "no entries in $ENTRY_DIR/ — nothing to release."
  set_output "has-changes" "false"
  set_output "bump" ""
  set_output "version" ""
  set_output "previous-version" ""
  exit 0
fi

bump=""
best=0
while IFS= read -r path; do
  [ -n "${path:-}" ] || continue
  raw="$(entry_raw_semver "$path")"
  [ -n "$raw" ] || die "$path has no 'semver:' header. Start the file with 'semver: major', 'semver: minor' or 'semver: patch'."
  lvl="$(normalize_bump "$raw")"
  [ -n "$lvl" ] || die "$path declares 'semver: $raw', which is not a bump level (${CL_BUMPS[*]})."
  r="$(bump_rank "$lvl")"
  if [ "$r" -gt "$best" ]; then best="$r"; bump="$lvl"; fi
done <"$list"

if [ -n "$FORCE_BUMP" ]; then
  log "overriding detected bump '$bump' with forced '$FORCE_BUMP'"
  bump="$FORCE_BUMP"
fi
[ -n "$bump" ] || die "could not determine a bump level from $ENTRY_DIR/"

# --- resolve the base version ----------------------------------------------

tag_version="$(version_from_tags "$TAG_PREFIX")"
cl_version="$(version_from_changelog "$CHANGELOG_FILE")"
prev="$(semver_max "$tag_version" "$cl_version")"

log "latest tag:              ${tag_version:-<none>}"
log "latest changelog heading: ${cl_version:-<none>}"
log "base version:            $prev"

if [ "$prev" = "0.0.0" ] && [ -z "$tag_version" ] && [ -z "$cl_version" ]; then
  log "no prior version found; starting from 0.0.0"
  prev_link=""
else
  prev_link="$prev"
fi

next="$(semver_bump "$prev" "$bump")"
log "next version:            $next  ($bump)"

if [ "$next" = "$(semver_bare "${cl_version:-}")" ]; then
  die "CHANGELOG.md already documents $next. Refusing to write a duplicate section."
fi

# --- rewrite the changelog --------------------------------------------------

changelog_ensure "$CHANGELOG_FILE"

section="$(mktemp)"
render_section "$next" "$RELEASE_DATE" "$list" >"$section"

changelog_insert "$CHANGELOG_FILE" "$section"
changelog_update_links "$CHANGELOG_FILE" "$next" "$prev_link" "$REPO_URL" "$TAG_PREFIX"

if [ -n "$VERSION_FILE" ]; then
  printf '%s\n' "$next" >"$VERSION_FILE"
  log "wrote $next to $VERSION_FILE"
fi

# --- stamp the version into contracts --------------------------------------

stamped=""
for spec in "${STAMP_SPECS[@]}"; do
  format="${spec%%|*}"
  paths_spec="${spec#*|}"
  [ -n "$paths_spec" ] || continue
  log "stamping $format targets:"
  # Assign first: a glob that matches nothing makes stamp_expand fail here,
  # rather than the loop quietly iterating zero times.
  targets="$(stamp_expand "$paths_spec" "$format path")"
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    stamp_file "$format" "$target" "$next"
    stamped="${stamped:+$stamped$'\n'}$target"
  done <<<"$targets"
done

# --- consume the entry files ------------------------------------------------

consumed=0
while IFS= read -r path; do
  [ -n "${path:-}" ] || continue
  if git rev-parse --git-dir >/dev/null 2>&1 && git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
    git rm --quiet -- "$path"
  else
    rm -f -- "$path"
  fi
  consumed=$((consumed + 1))
done <"$list"
log "consumed $consumed entry file(s)"

# `git rm` prunes a directory that becomes empty, so keep the entry directory
# itself alive for the next contributor.
mkdir -p "$ENTRY_DIR"
if [ -z "$(ls -A "$ENTRY_DIR" 2>/dev/null)" ]; then
  : >"$ENTRY_DIR/.gitkeep"
fi

if [ -n "$SECTION_OUT" ]; then
  cp "$section" "$SECTION_OUT"
fi

rm -f "$list" "$section"

set_output "has-changes" "true"
set_output "bump" "$bump"
set_output "version" "$next"
set_output "previous-version" "$prev"
set_output "tag" "${TAG_PREFIX}${next}"
set_output "entry-count" "$consumed"
set_output "stamped-files" "$stamped"
