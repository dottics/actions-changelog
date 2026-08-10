#!/usr/bin/env bash
# validate.sh — PR-time check that changelog entries are present and well-formed.
#
# Env:
#   ENTRY_DIR        default .changelog (flat <slug>.md files, `semver:` header)
#   REQUIRE_ENTRY    "true" to fail when a PR adds no entry at all
#   BASE_REF         base branch to diff against when REQUIRE_ENTRY is on
#   SKIP_LABELS      comma-separated PR labels that waive REQUIRE_ENTRY
#   PR_LABELS        comma-separated labels actually on the PR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

ENTRY_DIR="${ENTRY_DIR:-.changelog}"
REQUIRE_ENTRY="${REQUIRE_ENTRY:-false}"
BASE_REF="${BASE_REF:-}"
SKIP_LABELS="${SKIP_LABELS:-}"
PR_LABELS="${PR_LABELS:-}"

errors=0
fail() { printf '::error::%s\n' "$*" >&2; errors=$((errors + 1)); }

# --- structural checks ------------------------------------------------------

# Entries are flat files. Anything nested is invisible to the release, so it
# has to be an error rather than a silently skipped change.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if entry_is_legacy "$f" "$ENTRY_DIR"; then
    fail "'$f' uses the v1 bump-level layout. Move it to ${ENTRY_DIR}/$(basename "$f") and give it a 'semver:' header."
  else
    fail "'$f' is in a subdirectory of ${ENTRY_DIR}/ and will never be picked up. Entries are flat: ${ENTRY_DIR}/<short-slug>.md."
  fi
done < <(entries_nested "$ENTRY_DIR")

# --- per-entry checks -------------------------------------------------------

count=0
list="$(mktemp)"
entries_find "$ENTRY_DIR" >"$list"

while IFS= read -r path; do
  [ -n "${path:-}" ] || continue
  count=$((count + 1))

  raw="$(entry_raw_semver "$path")"
  if [ -z "$raw" ]; then
    fail "$path has no 'semver:' header. Start the file with 'semver: major', 'semver: minor' or 'semver: patch'."
  elif [ -z "$(normalize_bump "$raw")" ]; then
    fail "$path declares 'semver: $raw', which is not a bump level (${CL_BUMPS[*]})."
  fi

  raw="$(entry_raw_type "$path")"
  if [ -n "$raw" ] && [ -z "$(normalize_type "$raw")" ]; then
    fail "$path declares 'type: $raw', which is not a Keep a Changelog category (${CL_TYPES[*]})."
  fi

  if [ -z "$(entry_body "$path")" ]; then
    fail "$path has no body. Write the changelog line you want published below the header."
  fi

  case "$path" in
    *.md|*.markdown|*.txt) ;;
    *) warn "$path has no .md/.txt extension; it will still be picked up." ;;
  esac
done <"$list"

log "found $count changelog entr$([ "$count" = 1 ] && echo y || echo ies) under $ENTRY_DIR/"

# --- "every PR needs an entry" ---------------------------------------------

skip=false
if [ -n "$SKIP_LABELS" ] && [ -n "$PR_LABELS" ]; then
  IFS=',' read -ra _skips <<<"$SKIP_LABELS"
  for s in "${_skips[@]}"; do
    s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [ -n "$s" ] || continue
    case ",${PR_LABELS}," in
      *",$s,"*) skip=true; log "skipping entry requirement: PR is labelled '$s'" ;;
    esac
  done
fi

if [ "$REQUIRE_ENTRY" = "true" ] && [ "$skip" != "true" ]; then
  added=0
  if [ -n "$BASE_REF" ] && git rev-parse --verify --quiet "$BASE_REF" >/dev/null; then
    added="$(git diff --name-only --diff-filter=A "$BASE_REF"...HEAD -- "$ENTRY_DIR" | grep -c . || true)"
  else
    added="$count"
  fi
  if [ "$added" -eq 0 ]; then
    fail "This PR adds no changelog entry. Create ${ENTRY_DIR}/<short-slug>.md with a 'semver:' header describing the change."
  fi
fi

rm -f "$list"

set_output "entry-count" "$count"

if [ "$errors" -gt 0 ]; then
  die "$errors changelog validation problem(s)."
fi
log "changelog entries look good."
