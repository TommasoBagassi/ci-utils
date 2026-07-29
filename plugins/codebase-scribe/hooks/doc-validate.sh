#!/bin/bash
# PostToolUse hook: validates docs/*.md structure per the two-tier contract (spec §1
# "Structure contract"). Mature topics need only a positional, fence-aware TL;DR
# blockquote; stub topics (empty body, or any unfenced line beginning with the stub
# marker) need the 5-section skeleton plus TL;DR. Always exits 0; never writes to
# stderr.
# §1's positional TL;DR test is read strictly: the blockquote must be the first
# non-blank line after the `#` heading, and a fence opener is a non-blank line,
# so a file whose first post-heading content is a code fence fails the check.
# Fence-awareness exists to stop fenced *content* — headings, stub markers,
# section names — from being read as structure; it was never meant to widen the
# positional acceptance, and while it did, a topic with no blockquote in that
# position at all passed the check outright.
# --- file_path extraction: three rungs, strongest parser first ---
# 1. jq, and 2. python: both real JSON parsers, and both decode \uXXXX escapes
# including surrogate pairs. Python is the middle rung because it is present far
# more often than jq on the Windows/Git-Bash machines this plugin is developed
# on, and this repo already depends on it (scripts/check-sync.sh).
# 3. the awk scanner below, last resort only — for a machine with neither. It
# leaves \uXXXX literal, so a payload whose path carries an escaped non-ASCII
# character fails the [ -f ] test and the hook no-ops on a write it should have
# validated. That is a real gap in rung 3, named here as exactly that: it is why
# the scanner is last rather than the production path anywhere jq or python
# exists.
# SCRIBE_NO_JQ=1 skips rung 1 and SCRIBE_NO_PYTHON=1 skips rung 2 — test-only,
# so each rung is exercisable deterministically on a machine that has all three.
# The fallback is a real JSON scanner in awk, not a pattern match, because the
# three ways a pattern match got this wrong all failed toward *acting* on a
# payload it had not understood: it warned on malformed input, accepted a
# top-level "file_path" that no `.tool_input.file_path` selector would have
# returned, and turned two "file_path" occurrences anywhere in the payload into
# one newline-joined value that silently disabled validation. The scanner
# validates the whole document (balanced containers, well-formed strings and
# literals, exactly one top-level object, no trailing garbage) and selects the
# value by key path, so it agrees with `jq -r '.tool_input.file_path // empty'`
# on every case the harness exercises. It rejects — prints nothing, so the hook
# no-ops — on malformed input.
# Duplicate keys resolve to the LAST occurrence on all three rungs. A duplicate
# is not malformed input: RFC 8259 says names SHOULD be unique, and jq, python,
# and every mainstream parser keep the last one. An earlier revision had this
# scanner refuse a duplicated file_path as ambiguous, which is the one thing the
# three rungs must never do differently — rung 3 silently skipped validation on
# a payload rungs 1 and 2 both acted on. jq's behaviour is not changeable
# without reimplementing extraction over `jq --stream`, so the scanner is the
# side that moves.
# String escapes \\ \" \/ \n \r \t \b \f are decoded; \uXXXX is left literal
# (rung 3's named gap above), so such a path fails the [ -f ] test below and the
# hook no-ops rather than acting on a mis-decoded path. Any other escape, and a
# raw control character inside a string, is rejected outright — jq and python
# both refuse those, and the three rungs must draw the same boundary or the
# fallback acts on payloads the production paths would have thrown out.
# Windows-shaped paths (drive-letter
# or UNC) are normalized from backslash to forward-slash separators before
# matching, and the configured docs_dir is normalized the same way, so a
# Windows-native docs_dir setting matches a Windows-native incoming path. The
# one universe the normalizer cannot bridge is a Git-Bash-style /c/... path on
# one side and a C:/... path on the other; exact-prefix matching across those
# two spellings stays best-effort.
input=$(cat)

extract_file_path_jq() {
  printf '%s' "$1" | jq -r '.tool_input.file_path // empty' 2>/dev/null
}
# Rung 2. Same contract as rung 1, with a real JSON parse. The value is written
# as UTF-8 bytes rather than as text: this hook runs on consoles whose default
# encoding is cp1252, where writing a non-ASCII path through the text layer
# raises UnicodeEncodeError and loses the very payload this rung exists to
# handle. Exits non-zero only when the interpreter itself fails to run, which is
# what lets the caller tell "python says there is no file_path" (fall through to
# nothing) from "there is no usable python" (fall through to rung 3).
python_words=""
if [ "${SCRIBE_NO_PYTHON:-}" != "1" ]; then
  for cand in python3 python py; do
    if command -v "$cand" >/dev/null 2>&1; then
      if [ "$cand" = "py" ]; then python_words="$cand -3"; else python_words="$cand"; fi
      break
    fi
  done
fi
extract_file_path_python() {
  printf '%s' "$1" | $python_words -c '
import json, sys
try:
    payload = json.loads(sys.stdin.buffer.read().decode("utf-8"))
except Exception:
    raise SystemExit(0)
tool_input = payload.get("tool_input") if isinstance(payload, dict) else None
value = tool_input.get("file_path") if isinstance(tool_input, dict) else None
if isinstance(value, str) and value:
    sys.stdout.buffer.write(value.encode("utf-8"))
' 2>/dev/null
}
# Rung 3. Prints the value of .tool_input.file_path, or nothing at all if the
# payload is not a single well-formed JSON object or the key path is absent. A
# duplicated key path resolves to its last occurrence, as on rungs 1 and 2.
extract_file_path_fallback() {
  printf '%s' "$1" | awk '
    BEGIN {
      # JSON forbids a raw U+0000-U+001F inside a string. Built with sprintf
      # rather than a bracket-expression range because escape sequences inside
      # an awk bracket expression are not portably defined, and this test
      # decides whether the hook acts on a payload jq and python both reject.
      # U+0000 is absent: awk cannot hold it in a string, so it can neither be
      # tested for here nor survive into the extracted value.
      for (k = 1; k < 32; k++) ctrl = ctrl sprintf("%c", k)
    }
    function unescape(s,   i, n, c, e, out) {
      out = ""; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c != "\\" || i == n) { out = out c; continue }
        i++
        e = substr(s, i, 1)
        if (e == "n") out = out "\n"
        else if (e == "t") out = out "\t"
        else if (e == "r") out = out "\r"
        else if (e == "b") out = out "\b"
        else if (e == "f") out = out "\f"
        else if (e == "u") out = out "\\u"   # left undecoded on purpose
        else out = out e                     # \" \\ \/ and anything else
      }
      return out
    }
    function bad() { broken = 1; exit }
    # st[depth] is where the container sits in its own grammar, and every token
    # below is admitted only from the states that can precede it. Tracking merely
    # "an element is owed" was not enough: it left the separators optional, so
    # {"tool_input" {...}} (no colon) and {"a":1 "b":2} (no comma) both parsed.
    #   0 = empty container, expecting a first key/value or the close
    #   1 = member complete, expecting "," or the close
    #   2 = comma seen, expecting the next key/value
    #   3 = object key read, expecting ":"
    #   4 = object colon read, expecting the value
    function start_value() {
      if (depth == 0) bad()
      if (ctype[depth] == "o") { if (st[depth] != 4) bad() }
      else if (st[depth] != 0 && st[depth] != 2) bad()
    }
    function flush_literal(   v) {
      if (lit == "") return
      v = lit; lit = ""
      if (v !~ /^(true|false|null|-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?)$/) bad()
      st[depth] = 1
    }
    { data = data (NR > 1 ? "\n" : "") $0 }
    END {
      n = length(data)
      depth = 0; instr = 0; esc = 0; lit = ""; tops = 0; found = 0; iskey = 0
      for (i = 1; i <= n; i++) {
        c = substr(data, i, 1)
        if (instr) {
          # Only the nine escapes JSON defines, and no raw control character:
          # the scanner claimed to reject malformed JSON while accepting both,
          # so rung 3 acted on payloads rungs 1 and 2 refuse.
          if (esc)            { if (index("\"\\/bfnrtu", c) == 0) bad(); sb = sb c; esc = 0 }
          else if (c == "\\") { sb = sb c; esc = 1 }
          else if (index(ctrl, c) > 0) bad()
          else if (c == "\"") {
            instr = 0
            if (iskey) { key[depth] = unescape(sb); st[depth] = 3 }
            else {
              if (depth == 2 && ctype[1] == "o" && ctype[2] == "o" &&
                  key[1] == "tool_input" && key[2] == "file_path") {
                found++; value = unescape(sb)
              }
              st[depth] = 1
            }
          }
          else sb = sb c
          continue
        }
        if (c == "\"") {
          flush_literal()
          if (depth == 0) bad()
          if (ctype[depth] == "o") {
            # A string is the next key of this object only where a key is due; where a
            # value is due it is the value; anywhere else the payload is malformed.
            if (st[depth] == 0 || st[depth] == 2) iskey = 1
            else if (st[depth] == 4) iskey = 0
            else bad()
          } else {
            if (st[depth] != 0 && st[depth] != 2) bad()
            iskey = 0
          }
          instr = 1; sb = ""
          continue
        }
        if (c == "{" || c == "[") {
          flush_literal()
          if (depth == 0) { tops++; if (tops > 1 || c != "{") bad() } else start_value()
          depth++; ctype[depth] = (c == "{" ? "o" : "a"); key[depth] = ""; st[depth] = 0
          continue
        }
        if (c == "}" || c == "]") {
          flush_literal()
          if (depth == 0) bad()
          if ((c == "}") != (ctype[depth] == "o")) bad()
          # Only an empty container (0) or one whose last member is complete (1)
          # may close. 2 is "[1,]"/"{...,}", 3 a key with no colon, 4 a colon
          # with no value — none of which any JSON parser accepts.
          if (st[depth] != 0 && st[depth] != 1) bad()
          depth--
          if (depth > 0) st[depth] = 1
          continue
        }
        if (c == ":") { flush_literal(); if (depth == 0 || ctype[depth] != "o" || st[depth] != 3) bad(); st[depth] = 4; continue }
        if (c == ",") { flush_literal(); if (depth == 0 || st[depth] != 1) bad(); st[depth] = 2; continue }
        if (c == " " || c == "\t" || c == "\r" || c == "\n") { flush_literal(); continue }
        if (lit == "") start_value()
        lit = lit c
      }
      flush_literal()
      # found < 1, not found != 1: `value` is reassigned on every match, so a
      # duplicated key path leaves the last occurrence here — the same one jq
      # and python resolve to.
      if (broken || instr || depth != 0 || tops != 1 || found < 1) exit
      print value
    }
  ' 2>/dev/null
}
normalize_path() {
  local p="$1"
  if printf '%s' "$p" | grep -qE '^[A-Za-z]:[\\/]|^\\\\'; then
    printf '%s' "$p" | sed 's/\\/\//g'
  else
    printf '%s' "$p"
  fi
}

# Only the ABSENCE of a rung's tool falls through to the next one. A rung that
# ran and found no .tool_input.file_path has answered the question — the empty
# result is its answer, not a failure to be retried by a weaker parser.
file_path=""
if [ "${SCRIBE_NO_JQ:-}" != "1" ] && command -v jq >/dev/null 2>&1; then
  file_path="$(extract_file_path_jq "$input")"
elif [ -n "$python_words" ] && file_path="$(extract_file_path_python "$input")"; then
  :
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

# Two things the earlier line-shaped parser got wrong, both of which changed
# which files the hook validates rather than merely failing to parse:
#   * "${raw%%#*}" cut a quoted scalar at a "#" that is part of the value, so
#     docs_dir: "docs/#agents" became "docs/" and widened validation to every
#     unrelated tree under docs/;
#   * any indented descendant named docs_dir was accepted, so a nested
#     output.nested.docs_dir replaced the default and took validation off
#     docs/agents entirely.
# The scalar is therefore read quote-aware (an unquoted "#" opens a comment
# only at the start of the value or after whitespace, per YAML), and docs_dir
# is only honoured at the block's shallowest key indentation — that is, as a
# direct child of output:, never as a grandchild.
docs_dir="docs/agents"
if [ -n "$scribe_yml" ]; then
  raw="$(awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function scalar(v,   i, n, c, q, out) {
      v = trim(v)
      if (v == "") return ""
      q = substr(v, 1, 1)
      if (q == "\"" || q == "\047") {
        n = length(v); out = ""
        for (i = 2; i <= n; i++) {
          c = substr(v, i, 1)
          if (q == "\"" && c == "\\" && i < n) { i++; out = out substr(v, i, 1); continue }
          if (c == q) return out
          out = out c
        }
        return out
      }
      n = length(v); out = ""
      for (i = 1; i <= n; i++) {
        c = substr(v, i, 1)
        if (c == "#" && (i == 1 || substr(v, i - 1, 1) ~ /[[:space:]]/)) break
        out = out c
      }
      return trim(out)
    }
    /^output:[[:space:]]*(#.*)?$/ { in_output = 1; next }
    in_output && /^[^[:space:]]/ { in_output = 0 }
    in_output && /^[[:space:]]+[^[:space:]#]/ {
      match($0, /^[[:space:]]+/)
      ind = RLENGTH
      if (!min_ind || ind < min_ind) min_ind = ind
      if ($0 ~ /^[[:space:]]+docs_dir:/ && (!have || ind < dd_ind)) {
        have = 1; dd_ind = ind
        line = $0; sub(/^[[:space:]]+docs_dir:/, "", line)
        dd = scalar(line)
      }
    }
    END { if (have && dd_ind == min_ind) print dd }
  ' "$scribe_yml" 2>/dev/null)"
  if [ -n "$raw" ]; then
    # A leading "./" or a trailing slash would make the match patterns below
    # keep a segment no incoming path carries ("*/./docs/ai/*.md") or double the
    # separator ("*/docs/ai//*.md"), and match nothing at all — the hook would
    # go silent for every topic while the orchestrator, which normalizes both
    # (12a's link matching strips a leading "./"; Step 3 normalizes trailing
    # slashes), kept working. Strip both so the two agree on the same config
    # value. Leading first: "./" alone then reduces to the empty string and
    # leaves the default in place, where the reverse order would leave ".".
    raw="${raw#./}"
    raw="${raw%/}"
    [ -n "$raw" ] && docs_dir="$raw"
  fi
fi

# The incoming file_path is normalized above; the configured value must go
# through the same conversion or a Windows-native docs_dir ("C:\...\docs\ai")
# never matches the incoming "C:/.../docs/ai" and every topic write bypasses
# the hook silently.
docs_dir="$(normalize_path "$docs_dir")"

# --- path match: an absolute docs_dir is an exact prefix; otherwise accept both
# absolute (*/docs_dir/*.md) and repo-relative (docs_dir/*.md) forms. Absolute
# means POSIX (/...), UNC (//server/share/... after normalization), or a
# drive-letter path (C:/...) — matching only on a leading "/" left every
# Windows-native setting in the relative branch, where the exact-prefix rule
# never applied. ---
matched=0
case "$docs_dir" in
  /*|[A-Za-z]:/*)
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
    body_nonblank = 0; marker = 0; heading_seen = 0
    tldr_ok = 0; awaiting_tldr = 0
    sec1 = 0; sec2 = 0; sec3 = 0; sec4 = 0; sec5 = 0
  }
  # A UTF-8 BOM sits in front of line 1, so the frontmatter anchor
  # ($0 == "---") failed and the frontmatter block was parsed as body — a `#`
  # comment inside it then became the H1 anchor and the next line was judged as
  # the TL;DR position, so a correctly-structured file was reported as missing
  # its blockquote. Windows editors write a BOM routinely. The escape is octal,
  # not \xef\xbb\xbf: \x is a gawk extension POSIX awk does not define — under
  # `gawk --posix` the hex form silently fails to match and the BOM survives,
  # which is the one outcome this line exists to prevent.
  NR == 1 { sub(/^\357\273\277/, "") }
  # A CRLF topic file must compare the same as an LF one: every exact-match
  # test below ($0 == "---", line == "## " s1, ...) would otherwise fail on the
  # trailing \r. GNU Awk on mingw strips it for us; a POSIX awk does not, so
  # strip it explicitly rather than depend on the platform.
  { sub(/\r$/, "") }
  NR == 1 && $0 == "---" { fm = 1; next }
  fm == 1 {
    if ($0 == "---") fm = 0
    next
  }
  # Fenced lines are invisible to heading/TL;DR/section detection but they are
  # still body content: a mature topic whose whole body is one code fence must
  # not fall through to the stub branch and collect a five-section warning.
  # Only the marker that opened a fence closes it (CommonMark): while both
  # markers toggled one flag, a ``` line quoted inside a ~~~ block closed that
  # block, and everything below it — including a quoted stub marker — became
  # visible again, sending a mature topic down the stub branch.
  /^```/ || /^~~~/ {
    body_nonblank = 1
    # A fence opener is a non-blank line, so it occupies the TL;DR position. It
    # is not a blockquote, so a topic whose first post-heading content is a
    # fence fails the check — fence-awareness stops fenced content from being
    # read as structure, it does not excuse a missing blockquote.
    if (awaiting_tldr) awaiting_tldr = 0
    mark = (substr($0, 1, 3) == "```" ? "`" : "~")
    if (fence == 0) { fence = 1; fence_mark = mark }
    else if (mark == fence_mark) { fence = 0 }
    next
  }
  fence == 1 {
    if ($0 !~ /^[[:space:]]*$/) body_nonblank = 1
    next
  }
  {
    line = $0
    is_blank = (line ~ /^[[:space:]]*$/)
    if (!is_blank) body_nonblank = 1

    if (line ~ /^\*Stub — will be populated/) marker = 1

    if (!heading_seen && line ~ /^# /) {
      heading_seen = 1
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
    printf "%d %d %d %d %d %d %d %d\n", body_nonblank, marker, tldr_ok, sec1, sec2, sec3, sec4, sec5
  }
' "$file_path" 2>/dev/null)"

# empty result means the awk pass produced no output (e.g. the file exists but
# isn't readable) — bail out silently rather than feed empty vars to [ -eq ]
[ -n "$result" ] || exit 0

read -r body marker tldr sec1 sec2 sec3 sec4 sec5 <<<"$result"

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
  missing="${missing%,}"   # each element was appended with a trailing comma
  # The path is the only part of this envelope that is not a literal, and it is
  # interpolated into a JSON string: an unescaped double quote in it closed that
  # string early and emitted a payload no JSON consumer can read, so the host
  # dropped the warning entirely. Backslashes first, then quotes — the reverse
  # order would re-escape the backslashes this step just added. The element list
  # needs no such treatment; it is assembled from fixed strings above.
  escaped_path="$(printf '%s' "$file_path" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  echo "{\"systemMessage\": \"WARNING: $escaped_path is missing required elements:$missing.\"}"
fi
exit 0
