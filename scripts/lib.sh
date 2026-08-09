#!/usr/bin/env bash
# lib.sh — shared helpers for the changelog action.
# Sourced by validate.sh and release.sh. Not meant to be executed directly.

# Keep a Changelog categories, in the order they should appear in a release.
CL_TYPES=(Added Changed Deprecated Removed Fixed Security)
CL_BUMPS=(major minor patch)

die()  { printf '::error::%s\n' "$*" >&2; exit 1; }
warn() { printf '::warning::%s\n' "$*" >&2; }
log()  { printf '%s\n' "$*" >&2; }

# Emit a key=value pair to $GITHUB_OUTPUT (no-op when running locally).
set_output() {
  local key="$1" value="$2"
  printf '%s\n' "$key=$value" >&2
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  if [[ "$value" == *$'\n'* ]]; then
    local delim="ghadelim_$RANDOM$RANDOM"
    { printf '%s<<%s\n' "$key" "$delim"
      printf '%s\n' "$value"
      printf '%s\n' "$delim"; } >>"$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
  fi
}

# ---------------------------------------------------------------------------
# semver
# ---------------------------------------------------------------------------

semver_bare() { printf '%s' "${1#v}"; }

semver_valid() {
  [[ "$(semver_bare "$1")" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Print the greater of two versions (bare, no leading v). Empty args -> 0.0.0.
semver_max() {
  local a b
  a="$(semver_bare "${1:-0.0.0}")"; [ -n "$a" ] || a=0.0.0
  b="$(semver_bare "${2:-0.0.0}")"; [ -n "$b" ] || b=0.0.0
  printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1
}

semver_bump() {
  local v level major minor patch
  v="$(semver_bare "$1")"; level="$2"
  IFS=. read -r major minor patch <<<"$v"
  case "$level" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    *) die "unknown bump level: '$level'" ;;
  esac
  printf '%s.%s.%s' "$major" "$minor" "$patch"
}

bump_rank() {
  case "$1" in
    patch) printf '1' ;;
    minor) printf '2' ;;
    major) printf '3' ;;
    *)     printf '0' ;;
  esac
}

# ---------------------------------------------------------------------------
# version discovery
# ---------------------------------------------------------------------------

# Highest semver git tag matching "<prefix>X.Y.Z". Prints bare version or "".
version_from_tags() {
  local prefix="${1:-v}" tags
  git rev-parse --git-dir >/dev/null 2>&1 || { printf ''; return 0; }
  tags="$(git tag --list "${prefix}[0-9]*" 2>/dev/null \
          | sed "s|^${prefix}||" \
          | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
          | sort -V | tail -n1 || true)"
  printf '%s' "$tags"
}

# Topmost "## [X.Y.Z]" heading in a changelog. Prints bare version or "".
version_from_changelog() {
  local file="$1"
  [ -f "$file" ] || { printf ''; return 0; }
  sed -nE 's/^##[[:space:]]+\[?v?([0-9]+\.[0-9]+\.[0-9]+)\]?.*/\1/p' "$file" \
    | head -n1
}

# ---------------------------------------------------------------------------
# entry files
# ---------------------------------------------------------------------------

# Print "<bump>\t<path>" for every entry file under $1, patch..major order.
entries_find() {
  local dir="$1" bump path
  for bump in "${CL_BUMPS[@]}"; do
    [ -d "$dir/$bump" ] || continue
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      printf '%s\t%s\n' "$bump" "$path"
    done < <(find "$dir/$bump" -maxdepth 1 -type f \
               ! -name '.*' ! -name 'README*' \
               2>/dev/null | LC_ALL=C sort)
  done
}

# Any file directly in $dir (not in a bump subdir) is almost certainly a
# mistake — report it so validate can fail loudly.
entries_stray() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f ! -name '.*' ! -name 'README*' 2>/dev/null \
    | LC_ALL=C sort
}

# Directories under $dir that are not a valid bump level.
entries_bad_dirs() {
  local dir="$1" d name
  [ -d "$dir" ] || return 0
  while IFS= read -r d; do
    name="$(basename "$d")"
    case " ${CL_BUMPS[*]} " in
      *" $name "*) ;;
      *) printf '%s\n' "$d" ;;
    esac
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort)
}

# Default Keep a Changelog category when an entry does not declare one.
default_type_for_bump() {
  case "$1" in
    major) printf 'Changed' ;;
    minor) printf 'Added' ;;
    *)     printf 'Fixed' ;;
  esac
}

# Canonicalise user-supplied category casing; prints "" when unrecognised.
normalize_type() {
  local want t
  want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for t in "${CL_TYPES[@]}"; do
    [ "$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')" = "$want" ] && { printf '%s' "$t"; return 0; }
  done
  printf ''
}

entry_has_type_header() {
  head -n1 "$1" 2>/dev/null | grep -qiE '^[[:space:]]*type:[[:space:]]*[A-Za-z]+[[:space:]]*$'
}

# Raw declared category (may be invalid) or "" when absent.
entry_raw_type() {
  entry_has_type_header "$1" || { printf ''; return 0; }
  head -n1 "$1" | sed -E 's/^[[:space:]]*[Tt][Yy][Pp][Ee]:[[:space:]]*//; s/[[:space:]]*$//'
}

# Resolved category for an entry: declared, else derived from the bump level.
entry_type() {
  local path="$1" bump="$2" raw norm
  raw="$(entry_raw_type "$path")"
  if [ -n "$raw" ]; then
    norm="$(normalize_type "$raw")"
    [ -n "$norm" ] && { printf '%s' "$norm"; return 0; }
  fi
  default_type_for_bump "$bump"
}

# Entry text with the optional type header stripped and blank edges trimmed.
entry_body() {
  local path="$1" text
  if entry_has_type_header "$path"; then
    text="$(tail -n +2 "$path")"
  else
    text="$(cat "$path")"
  fi
  printf '%s' "$text" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

# Render one entry as markdown bullet(s).
# Already-bulleted bodies pass through; prose becomes a single bullet with
# hanging indentation on continuation lines.
entry_render() {
  local path="$1" body first_line rest
  body="$(entry_body "$path")"
  [ -n "$body" ] || return 0
  if printf '%s' "$body" | grep -qE '^[[:space:]]*[-*][[:space:]]'; then
    printf '%s\n' "$body"
    return 0
  fi
  first_line="$(printf '%s' "$body" | head -n1)"
  rest="$(printf '%s' "$body" | tail -n +2)"
  printf -- '- %s\n' "$first_line"
  if [ -n "$rest" ]; then
    printf '%s\n' "$rest" | sed -E 's/^(.*)$/  \1/; s/[[:space:]]+$//'
  fi
}

# ---------------------------------------------------------------------------
# changelog rendering
# ---------------------------------------------------------------------------

# render_section VERSION DATE ENTRIES_TSV
# ENTRIES_TSV is a file of "<bump>\t<path>" lines. Prints the release section
# followed by a trailing blank line.
render_section() {
  local version="$1" date="$2" tsv="$3" type bump path have

  printf '## [%s] - %s\n' "$version" "$date"
  for type in "${CL_TYPES[@]}"; do
    have=0
    while IFS=$'\t' read -r bump path; do
      [ -n "${path:-}" ] || continue
      [ "$(entry_type "$path" "$bump")" = "$type" ] || continue
      if [ "$have" -eq 0 ]; then
        printf '\n### %s\n\n' "$type"
        have=1
      fi
      entry_render "$path"
    done <"$tsv"
  done
  printf '\n'
}

CHANGELOG_PREAMBLE='# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
'

changelog_ensure() {
  local file="$1"
  [ -f "$file" ] && return 0
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$CHANGELOG_PREAMBLE" >"$file"
}

# Insert SECTION_FILE above the newest existing release heading.
changelog_insert() {
  local file="$1" section="$2" at tmp
  tmp="$(mktemp)"

  at="$(grep -nE '^##[[:space:]]' "$file" | head -n1 | cut -d: -f1 || true)"
  if [ -z "$at" ]; then
    at="$(grep -nE '^\[[^]]+\]:[[:space:]]' "$file" | head -n1 | cut -d: -f1 || true)"
  fi

  if [ -z "$at" ]; then
    # No releases and no link refs yet: append to the end of the preamble.
    { sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$file"
      printf '\n'
      cat "$section"
    } >"$tmp"
  else
    { head -n "$((at - 1))" "$file" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
      printf '\n'
      cat "$section"
      tail -n +"$at" "$file"
    } >"$tmp"
  fi

  mv "$tmp" "$file"
}

# Add/refresh the "[X.Y.Z]: <url>" reference for VERSION at the top of the
# trailing link-reference block.
changelog_update_links() {
  local file="$1" version="$2" prev="$3" repo_url="$4" tag_prefix="$5"
  [ -n "$repo_url" ] || return 0

  local line
  if [ -n "$prev" ]; then
    line="[$version]: $repo_url/compare/${tag_prefix}${prev}...${tag_prefix}${version}"
  else
    line="[$version]: $repo_url/releases/tag/${tag_prefix}${version}"
  fi

  local tmp body_end total start
  tmp="$(mktemp)"
  # Drop any stale definition for this exact version.
  grep -vE "^\[${version//./\\.}\]:[[:space:]]" "$file" >"$tmp" || true
  mv "$tmp" "$file"

  total="$(wc -l <"$file")"
  # Walk back from EOF over blank lines and link-ref lines to find the block.
  start=$((total + 1))
  body_end="$total"
  while [ "$body_end" -ge 1 ]; do
    local l
    l="$(sed -n "${body_end}p" "$file")"
    if [ -z "$l" ]; then
      body_end=$((body_end - 1))
      continue
    fi
    if printf '%s' "$l" | grep -qE '^\[[^]]+\]:[[:space:]]'; then
      start="$body_end"
      body_end=$((body_end - 1))
      continue
    fi
    break
  done

  tmp="$(mktemp)"
  if [ "$start" -le "$total" ]; then
    { head -n "$((start - 1))" "$file"
      printf '%s\n' "$line"
      tail -n +"$start" "$file"
    } >"$tmp"
  else
    { sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$file"
      printf '\n%s\n' "$line"
    } >"$tmp"
  fi
  mv "$tmp" "$file"
}
