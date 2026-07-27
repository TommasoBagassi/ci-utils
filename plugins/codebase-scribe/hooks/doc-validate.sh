#!/bin/bash
# PostToolUse hook: validates docs/*.md structure per the two-tier contract (spec §1
# "Structure contract"). Mature topics need only a positional, fence-aware TL;DR
# blockquote; stub topics (empty body, or any unfenced line beginning with the stub
# marker) need the 5-section skeleton plus TL;DR. Always exits 0; never writes to
# stderr. SCRIBE_NO_JQ=1 forces the grep/sed extraction path — test-only, so the
# fallback branch is exercisable deterministically on machines that do have jq.
# The grep/sed fallback unescapes \\, \" and \/ in file_path (the sequences a real
# path can contain); \uXXXX is not decoded. Windows-shaped paths (drive-letter or
# UNC) are normalized from backslash to forward-slash separators before matching;
# under a leading-/ (exact-prefix) docs_dir on Windows, the configured value and
# the incoming path can be in different path universes (/c/... vs C:/...), so
# exact-prefix matching there is best-effort.
input=$(cat)

extract_file_path_jq() {
  printf '%s' "$1" | jq -r '.tool_input.file_path // empty' 2>/dev/null
}
extract_file_path_fallback() {
  printf '%s' "$1" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null \
    | sed -E 's/.*:[[:space:]]*"(.*)"/\1/' \
    | sed -e 's/\\\\/\\/g' -e 's/\\"/"/g' -e 's/\\\//\//g'
}
normalize_path() {
  local p="$1"
  if printf '%s' "$p" | grep -qE '^[A-Za-z]:[\\/]|^\\\\'; then
    printf '%s' "$p" | sed 's/\\/\//g'
  else
    printf '%s' "$p"
  fi
}

file_path=""
if [ "${SCRIBE_NO_JQ:-}" != "1" ] && command -v jq >/dev/null 2>&1; then
  file_path="$(extract_file_path_jq "$input")"
else
  file_path="$(extract_file_path_fallback "$input")"
fi

[ -n "$file_path" ] || exit 0
file_path="$(normalize_path "$file_path")"
[ -f "$file_path" ] || exit 0

case "$file_path" in
  */STATUS.md) exit 0 ;;
esac

# --- resolve docs_dir from .scribe.yml ---
scribe_yml=""
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.scribe.yml" ]; then
  scribe_yml="$CLAUDE_PROJECT_DIR/.scribe.yml"
elif [ -f "./.scribe.yml" ]; then
  scribe_yml="./.scribe.yml"
fi

docs_dir="docs/agents"
if [ -n "$scribe_yml" ]; then
  raw="$(awk '
    /^output:[[:space:]]*$/ { in_output=1; next }
    in_output && /^[^[:space:]]/ { in_output=0 }
    in_output && /^[[:space:]]+docs_dir:[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]+docs_dir:[[:space:]]*/, "", line)
      print line
      exit
    }
  ' "$scribe_yml" 2>/dev/null)"
  if [ -n "$raw" ]; then
    raw="${raw%%#*}"
    raw="$(printf '%s' "$raw" | sed -e 's/[[:space:]]*$//')"
    raw="${raw#\"}"; raw="${raw%\"}"
    raw="${raw#\'}"; raw="${raw%\'}"
    [ -n "$raw" ] && docs_dir="$raw"
  fi
fi

# --- path match: leading-/ docs_dir is an exact prefix; otherwise accept both
# absolute (*/docs_dir/*.md) and repo-relative (docs_dir/*.md) forms ---
matched=0
case "$docs_dir" in
  /*)
    case "$file_path" in
      "$docs_dir"/*.md) matched=1 ;;
    esac
    ;;
  *)
    case "$file_path" in
      */"$docs_dir"/*.md) matched=1 ;;
      "$docs_dir"/*.md) matched=1 ;;
    esac
    ;;
esac
[ "$matched" -eq 1 ] || exit 0

# --- fence-aware single pass: frontmatter and fenced (``` / ~~~) lines are
# invisible to heading, TL;DR, marker and section-heading detection ---
result="$(awk -v s1="Key Entry Points" -v s2="Patterns & Conventions" -v s3="Gotchas" \
             -v s4="Dependencies & Context" -v s5="Links" '
  BEGIN {
    fence = 0; fm = 0
    body_nonblank = 0; marker = 0; heading_found = 0; heading_seen = 0
    tldr_ok = 0; awaiting_tldr = 0
    sec1 = 0; sec2 = 0; sec3 = 0; sec4 = 0; sec5 = 0
  }
  NR == 1 && $0 == "---" { fm = 1; next }
  fm == 1 {
    if ($0 == "---") fm = 0
    next
  }
  /^```/ || /^~~~/ { fence = !fence; next }
  fence == 1 { next }
  {
    line = $0
    is_blank = (line ~ /^[[:space:]]*$/)
    if (!is_blank) body_nonblank = 1

    if (line ~ /^\*Stub — will be populated/) marker = 1

    if (!heading_seen && line ~ /^# /) {
      heading_seen = 1
      heading_found = 1
      awaiting_tldr = 1
      next
    }

    if (awaiting_tldr && !is_blank) {
      if (line ~ /^>/) tldr_ok = 1
      awaiting_tldr = 0
    }

    if (line == "## " s1) sec1 = 1
    if (line == "## " s2) sec2 = 1
    if (line == "## " s3) sec3 = 1
    if (line == "## " s4) sec4 = 1
    if (line == "## " s5) sec5 = 1
  }
  END {
    printf "%d %d %d %d %d %d %d %d %d\n", body_nonblank, marker, heading_found, tldr_ok, sec1, sec2, sec3, sec4, sec5
  }
' "$file_path" 2>/dev/null)"

# empty result means the awk pass produced no output (e.g. the file exists but
# isn't readable) — bail out silently rather than feed empty vars to [ -eq ]
[ -n "$result" ] || exit 0

read -r body marker heading tldr sec1 sec2 sec3 sec4 sec5 <<<"$result"

missing=""
if [ "$body" -eq 0 ] || [ "$marker" -eq 1 ]; then
  [ "$sec1" -eq 1 ] || missing="$missing Key Entry Points,"
  [ "$sec2" -eq 1 ] || missing="$missing Patterns & Conventions,"
  [ "$sec3" -eq 1 ] || missing="$missing Gotchas,"
  [ "$sec4" -eq 1 ] || missing="$missing Dependencies & Context,"
  [ "$sec5" -eq 1 ] || missing="$missing Links,"
fi
[ "$tldr" -eq 1 ] || missing="$missing TL;DR blockquote,"

if [ -n "$missing" ]; then
  echo "{\"systemMessage\": \"WARNING: $file_path is missing required elements:$missing.\"}"
fi
exit 0
