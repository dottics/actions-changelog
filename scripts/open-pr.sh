#!/usr/bin/env bash
# open-pr.sh — commit the release changes onto a branch and open (or refresh)
# the version-bump pull request.
#
# Env:
#   VERSION         required, e.g. 1.4.0
#   BUMP            major|minor|patch
#   BASE_BRANCH     branch the PR targets (default: current branch)
#   BRANCH_PREFIX   default release/
#   TAG_PREFIX      default v
#   COMMIT_MESSAGE  default "chore(release): <tag>"
#   PR_TITLE        default "chore(release): <tag>"
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
BRANCH_PREFIX="${BRANCH_PREFIX:-release/}"
BASE_BRANCH="${BASE_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
TAG="${TAG_PREFIX}${VERSION}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-chore(release): $TAG}"
PR_TITLE="${PR_TITLE:-chore(release): $TAG}"
PR_LABELS="${PR_LABELS:-}"
SECTION_FILE="${SECTION_FILE:-}"
DRY_RUN="${DRY_RUN:-false}"
BRANCH="${BRANCH_PREFIX}${TAG}"

git config user.name  "${GIT_USER_NAME:-github-actions[bot]}"
git config user.email "${GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

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

existing="$(gh pr list --head "$BRANCH" --base "$BASE_BRANCH" --state open \
              --json url --jq '.[0].url // empty' 2>/dev/null || true)"

if [ -n "$existing" ]; then
  gh pr edit "$existing" --title "$PR_TITLE" --body-file "$body_file" >/dev/null
  url="$existing"
  log "updated existing PR: $url"
else
  url="$(gh pr create \
          --head "$BRANCH" \
          --base "$BASE_BRANCH" \
          --title "$PR_TITLE" \
          --body-file "$body_file")"
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
