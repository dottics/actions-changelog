#!/usr/bin/env bash
# validate.sh — PR-time check that changelog entries are present and well-formed.
#
# Env:
#   ENTRY_DIR        default .changelog
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

while IFS= read -r d; do
  [ -n "$d" ] || continue
  fail "'$d' is not a valid bump level directory. Use ${ENTRY_DIR}/major, ${ENTRY_DIR}/minor or ${ENTRY_DIR}/patch."
done < <(entries_bad_dirs "$ENTRY_DIR")

while IFS= read -r f; do
  [ -n "$f" ] || continue
  fail "'$f' sits directly in ${ENTRY_DIR}/. Move it into ${ENTRY_DIR}/{major,minor,patch}/."
done < <(entries_stray "$ENTRY_DIR")

# --- per-entry checks -------------------------------------------------------

count=0
tsv="$(mktemp)"
entries_find "$ENTRY_DIR" >"$tsv"

while IFS=$'\t' read -r _ path; do
  [ -n "${path:-}" ] || continue
  count=$((count + 1))

  raw="$(entry_raw_type "$path")"
  if [ -n "$raw" ] && [ -z "$(normalize_type "$raw")" ]; then
    fail "$path declares 'type: $raw', which is not a Keep a Changelog category (${CL_TYPES[*]})."
  fi

  if [ -z "$(entry_body "$path")" ]; then
    fail "$path is empty. Write the changelog line you want published."
  fi

  case "$path" in
    *.md|*.markdown|*.txt) ;;
    *) warn "$path has no .md/.txt extension; it will still be picked up." ;;
  esac
done <"$tsv"

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
    fail "This PR adds no changelog entry. Create ${ENTRY_DIR}/{major|minor|patch}/<short-slug>.md describing the change."
  fi
fi

rm -f "$tsv"

set_output "entry-count" "$count"

if [ "$errors" -gt 0 ]; then
  die "$errors changelog validation problem(s)."
fi
log "changelog entries look good."
