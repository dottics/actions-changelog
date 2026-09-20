#!/usr/bin/env bash
# stamp.sh — write the release version into contract and manifest files.
#
# Sourced by release.sh. Every supported format is one `stamp_<format>`
# function plus one entry in the `stamp_file` dispatch table, so adding
# AsyncAPI, protobuf, Helm charts or package.json later is a local change.
#
# Stampers must be format-preserving: they rewrite exactly the one value and
# leave comments, key order, indentation and quote style alone.

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

# stamp_file FORMAT PATH VERSION
stamp_file() {
  local format="$1" path="$2" version="$3"
  [ -f "$path" ] || die "$format target '$path' does not exist."
  case "$format" in
    openapi) stamp_openapi "$path" "$version" ;;
    *)       die "unknown stamp format '$format' (no stamper registered)." ;;
  esac
}

# Expand a newline/comma-separated, glob-friendly list into one path per line.
# Globs that match nothing are reported so a typo cannot pass silently.
stamp_expand() {
  local spec="$1" label="$2" item p matched
  local -a out=()
  # A here-string guarantees a trailing newline, so `read` does not drop the
  # final entry when the caller's value has none.
  while IFS= read -r item; do
    item="$(printf '%s' "$item" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [ -n "$item" ] || continue
    matched=0
    # shellcheck disable=SC2086  # deliberate glob expansion
    for p in $item; do
      [ -e "$p" ] || continue
      out+=("$p")
      matched=1
    done
    [ "$matched" = 1 ] || die "$label '$item' matched no files."
  done <<<"$(printf '%s' "$spec" | tr ',' '\n')"
  [ "${#out[@]}" -gt 0 ] || return 0
  printf '%s\n' "${out[@]}"
}

# ---------------------------------------------------------------------------
# openapi — sets info.version, in YAML or JSON
# ---------------------------------------------------------------------------

stamp_openapi() {
  local path="$1" version="$2" kind tmp rc
  kind="$(openapi_kind "$path")"
  tmp="$(mktemp)"

  rc=0
  case "$kind" in
    json) awk -v VERSION="$version" "$AWK_JSON_INFO_VERSION" "$path" >"$tmp" || rc=$? ;;
    *)    awk -v VERSION="$version" "$AWK_YAML_INFO_VERSION" "$path" >"$tmp" || rc=$? ;;
  esac

  case "$rc" in
    0) ;;
    3) rm -f "$tmp"; die "no top-level 'info.version' found in $path." ;;
    4) rm -f "$tmp"; die "'info' in $path uses flow style ({...}); rewrite it as a block mapping so the version can be stamped." ;;
    *) rm -f "$tmp"; die "failed to stamp $path (awk exit $rc)." ;;
  esac

  if cmp -s "$path" "$tmp"; then
    log "  $path already at $version"
    rm -f "$tmp"
    return 0
  fi
  cat "$tmp" >"$path"   # preserve the original file mode
  rm -f "$tmp"
  log "  $path -> info.version: $version"
}

openapi_kind() {
  case "$1" in
    *.json) printf 'json'; return 0 ;;
    *.yaml|*.yml) printf 'yaml'; return 0 ;;
  esac
  # No decisive extension: sniff the first non-blank, non-comment character.
  if head -c 4096 "$1" | grep -qE '^[[:space:]]*\{'; then
    printf 'json'
  else
    printf 'yaml'
  fi
}

# --- YAML: line-based, only touches `version:` directly under top-level `info:`
read -r -d '' AWK_YAML_INFO_VERSION <<'AWK' || true
BEGIN { in_info = 0; child_indent = -1; done = 0; flow = 0 }
{
  line = $0

  if (!done && line ~ /^[^[:space:]#-][^:]*:/) {            # a top-level key
    key = line
    sub(/:.*$/, "", key)
    gsub(/^["']|["']$/, "", key)
    if (key == "info") {
      rest = line
      sub(/^[^:]*:/, "", rest)
      sub(/^[[:space:]]+/, "", rest)
      sub(/[[:space:]]*#.*$/, "", rest)
      if (rest ~ /^\{/) { flow = 1; exit 4 }                # flow mapping
      in_info = 1
      child_indent = -1
    } else {
      in_info = 0
    }
    print line
    next
  }

  if (!done && in_info && line !~ /^[[:space:]]*$/ && line !~ /^[[:space:]]*#/) {
    match(line, /^[[:space:]]*/)
    ind = RLENGTH
    if (child_indent < 0) child_indent = ind
    if (ind == child_indent &&
        match(line, /^[[:space:]]*("version"|'version'|version)[[:space:]]*:[[:space:]]*/)) {
      pre  = substr(line, 1, RLENGTH)
      rest = substr(line, RLENGTH + 1)
      q = ""
      if (rest ~ /^"/)      q = "\""
      else if (rest ~ /^'/)  q = "'"
      if (q != "") {
        close_at = index(substr(rest, 2), q)
        tail = (close_at > 0) ? substr(rest, close_at + 2) : ""
        print pre q VERSION q tail
      } else {
        tail = rest
        sub(/^[^[:space:]]*/, "", tail)
        print pre VERSION tail
      }
      done = 1
      next
    }
  }

  print line
}
END { if (flow) exit 4; if (!done) exit 3 }
AWK

# --- JSON: brace/string-aware scan, replaces info.version in place
read -r -d '' AWK_JSON_INFO_VERSION <<'AWK' || true
{ buf = buf $0 "\n" }
END {
  n = length(buf)
  depth = 0; instr = 0; esc = 0; tokstart = 0
  pending_info = 0; in_info = 0; info_depth = -1

  for (i = 1; i <= n; i++) {
    c = substr(buf, i, 1)

    if (instr) {
      if (esc)            { esc = 0 }
      else if (c == "\\") { esc = 1 }
      else if (c == "\"") {
        instr = 0
        key = substr(buf, tokstart + 1, i - tokstart - 1)
        j = i + 1
        while (j <= n && substr(buf, j, 1) ~ /[ \t\r\n]/) j++
        if (substr(buf, j, 1) == ":") {
          if (depth == 1 && key == "info") {
            pending_info = 1
          } else if (in_info && depth == info_depth && key == "version") {
            k = j + 1
            while (k <= n && substr(buf, k, 1) ~ /[ \t\r\n]/) k++
            if (substr(buf, k, 1) == "\"") {
              m = k + 1; e = 0
              while (m <= n) {
                cc = substr(buf, m, 1)
                if (e)             { e = 0 }
                else if (cc == "\\") { e = 1 }
                else if (cc == "\"") { break }
                m++
              }
              printf "%s%s%s", substr(buf, 1, k), VERSION, substr(buf, m)
              exit 0
            }
          }
        }
      }
    } else {
      if (c == "\"") { instr = 1; tokstart = i }
      else if (c == "{" || c == "[") {
        depth++
        if (pending_info) {
          if (c == "{") { in_info = 1; info_depth = depth }
          pending_info = 0
        }
      }
      else if (c == "}" || c == "]") {
        if (in_info && depth == info_depth) in_info = 0
        depth--
      }
    }
  }
  exit 3
}
AWK
