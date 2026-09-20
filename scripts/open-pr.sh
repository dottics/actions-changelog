#!/usr/bin/env bash
# open-pr.sh — commit the release changes onto a branch and open (or refresh)
# the version-bump pull request.
#
# Env:
#   VERSION         required, e.g. 1.4.0
#   BUMP            major|minor|patch
#   BASE_BRANCH     branch the PR targets (default: current branch)
#   BRANCH_PREFIX   default rel/
#   TAG_PREFIX      default v
#   COMMIT_MESSAGE  default "chore(rel/<tag>)"
#   PR_TITLE        default "chore(rel/<tag>)"
#   PR_LABELS       comma-separated labels to apply
#   SECTION_FILE    rendered changelog section, embedded in the PR body
#   DRY_RUN         "true" to skip push / gh entirely
#   GH_TOKEN        token used by the gh CLI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

VERSION="${VERSION:?VERSION is required}"
BUMP="${BUMP:-}"
TAG_PREFIX="${TAG_PREFIX:-v}"
BRANCH_PREFIX="${BRANCH_PREFIX:-rel/}"
BASE_BRANCH="${BASE_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
TAG="${TAG_PREFIX}${VERSION}"
BRANCH="${BRANCH_PREFIX}${TAG}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-send-it($BRANCH)}"
PR_TITLE="${PR_TITLE:-send-it($BRANCH)}"
PR_LABELS="${PR_LABELS:-}"
SECTION_FILE="${SECTION_FILE:-}"
DRY_RUN="${DRY_RUN:-false}"

git config user.name  "${GIT_USER_NAME:-github-actions[bot]}"
git config user.email "${GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

printf 'Preparing to create branch: %s\n' "$BRANCH"

git switch --force-create "$BRANCH" >/dev/null 2>&1 || git checkout -B "$BRANCH"

git add -A
if git diff --cached --quiet; then
  log "nothing staged — no PR to open."
  set_output "pull-request-url" ""
  exit 0
fi
git commit --quiet -m "$COMMIT_MESSAGE"
log "committed on $BRANCH"

body_file="$(mktemp)"
# shellcheck disable=SC2016  # backticks below are markdown, not substitution
{
  printf 'Automated release prep for **%s** (`%s` bump).\n\n' "$TAG" "${BUMP:-unknown}"
  printf 'This PR was opened because entries were found in the changelog directory on `%s`.\n' "$BASE_BRANCH"
  printf 'Merging it publishes the changelog section below and clears the consumed entry files.\n\n'
  if [ -n "${STAMPED:-}" ]; then
    printf 'Version stamped into:\n\n'
    printf '%s\n' "$STAMPED" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      printf -- '- `%s`\n' "$f"
    done
    printf '\n'
  fi
  printf -- '---\n\n'
  if [ -n "$SECTION_FILE" ] && [ -f "$SECTION_FILE" ]; then
    cat "$SECTION_FILE"
  fi
  printf '\n'
  printf -- '<!-- changelog-action: %s -->\n' "$TAG"
} >"$body_file"

if [ "$DRY_RUN" = "true" ]; then
  log "DRY_RUN=true — skipping push and PR creation."
  log "--- branch: $BRANCH -> $BASE_BRANCH"
  log "--- PR body:"
  cat "$body_file" >&2
  set_output "pull-request-url" ""
  set_output "branch" "$BRANCH"
  exit 0
fi

git push --force-with-lease --set-upstream origin "$BRANCH"

command -v gh >/dev/null 2>&1 || die "gh CLI not found on the runner."

# ── find all open release PRs targeting this base ─────────────────────────────
# Search by prefix so a stale lower-version PR is detected even when the
# computed version has changed (e.g. patch → minor bump after a new merge).
release_prs="$(gh pr list --base "$BASE_BRANCH" --state open \
                 --json url,headRefName \
                 --jq "[.[] | select(.headRefName | startswith(\"$BRANCH_PREFIX\"))]" \
                 2>/dev/null || true)"
release_prs="${release_prs:-[]}"

existing_url=""

# Iterate: close stale lower-version PRs; capture a matching same-version one.
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  pr_url="$(printf '%s' "$entry" | jq -r '.url')"
  pr_ref="$(printf '%s' "$entry" | jq -r '.headRefName')"
  if [ "$pr_ref" = "$BRANCH" ]; then
    existing_url="$pr_url"
  else
    # Compare versions before closing — never close a higher-version PR.
    # Strip branch prefix then tag prefix to get the bare semver.
    stale_ver="$(semver_bare "${pr_ref#"$BRANCH_PREFIX"}")"
    new_ver="$(semver_bare "$TAG")"
    if [ "$(semver_max "$stale_ver" "$new_ver")" = "$new_ver" ] && [ "$stale_ver" != "$new_ver" ]; then
      log "closing stale release PR $pr_url ($pr_ref — superseded by $TAG)"
      gh pr close "$pr_url" \
        --comment "Superseded by $TAG — a higher semver version was detected from new changelog entries on \`$BASE_BRANCH\`." \
        2>/dev/null || warn "could not close stale release PR $pr_url (non-fatal)"
    else
      # Stale PR has an equal or higher version. This should not happen in normal
      # flow — release.sh recomputes from all entries still on base, so it would
      # also pick the higher bump. Log and leave it untouched.
      warn "open release PR $pr_url ($pr_ref) has version >= $TAG — leaving it open; investigate if unexpected"
    fi
  fi
done < <(printf '%s\n' "$release_prs" | jq -c '.[]' 2>/dev/null || true)

# ── open or refresh the release PR ────────────────────────────────────────────
if [ -n "$existing_url" ]; then
  gh pr edit "$existing_url" --title "$PR_TITLE" --body-file "$body_file" >/dev/null 2>&1 \
    || warn "could not refresh existing PR title/body (non-fatal)"
  url="$existing_url"
  log "updated existing PR: $url"
else
  # Capture stdout+stderr so "a pull request already exists: <url>" can be
  # recovered if gh pr list returned empty due to a GraphQL warning.
  create_out="$(gh pr create \
          --head "$BRANCH" \
          --base "$BASE_BRANCH" \
          --title "$PR_TITLE" \
          --body-file "$body_file" 2>&1)" || true
  url="$(printf '%s' "$create_out" | grep -Eo 'https://github\.com/[^[:space:]]*/pull/[0-9]+' | head -1)"
  if [ -z "$url" ]; then
    printf '%s\n' "$create_out" >&2
    die "failed to create or find release PR for branch '$BRANCH'"
  fi
  log "opened PR: $url"
fi

if [ -n "$PR_LABELS" ]; then
  IFS=',' read -ra _labels <<<"$PR_LABELS"
  for l in "${_labels[@]}"; do
    l="$(printf '%s' "$l" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [ -n "$l" ] || continue
    gh pr edit "$url" --add-label "$l" >/dev/null 2>&1 \
      || warn "could not add label '$l' (does it exist in the repo?)"
  done
fi

rm -f "$body_file"
set_output "pull-request-url" "$url"
set_output "branch" "$BRANCH"
