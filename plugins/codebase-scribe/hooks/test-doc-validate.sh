#!/bin/bash
# Test harness for doc-validate.sh. Run from this directory: bash test-doc-validate.sh
set -u
HOOK="$(cd "$(dirname "$0")" && pwd)/doc-validate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

invoke() { # $1=file_path
  printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash "$HOOK"
}
expect_warn() { # $1=name $2=path — asserts warning on stdout, clean stderr, exit 0
  out="$(invoke "$2" 2>"$TMP/err")"; rc=$?
  if [ $rc -eq 0 ] && [ ! -s "$TMP/err" ] && printf '%s' "$out" | grep -q '"systemMessage".*WARNING'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL(want-warn)[$MODE]: $1 rc=$rc"; fi
}
expect_silent() { # $1=name $2=path — asserts empty stdout, clean stderr, exit 0
  out="$(invoke "$2" 2>"$TMP/err")"; rc=$?
  if [ $rc -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP/err" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL(want-silent)[$MODE]: $1 rc=$rc -> $out"; fi
}

run_cases() {
  D="$TMP/repo/docs/agents"; mkdir -p "$D"; cd "$TMP/repo"
  export CLAUDE_PROJECT_DIR="$TMP/repo"   # pin the hook’s primary resolution root; the relative-path case below re-runs with it unset

  # mature, domain headings, valid TL;DR -> silent
  printf -- '---\nscribe:\n  scan: "abc1234"\n---\n# Topic\n\n> TLDR here.\n\n## Graph Data Model\nbody\n' > "$D/good.md"
  expect_silent mature-good "$D/good.md"
  # mature, blockquote only inside a later section -> warn
  printf -- '---\nx: 1\n---\n# Topic\n\nintro\n\n## Notes\n> not a tldr\n' > "$D/late-quote.md"
  expect_warn mature-late-quote "$D/late-quote.md"
  # no # heading at all -> warn
  printf -- '---\nx: 1\n---\nno heading\n' > "$D/no-heading.md"
  expect_warn no-heading "$D/no-heading.md"
  # fenced "# heading" before real one must not anchor the check
  printf -- '---\nx: 1\n---\n```\n# fake\n```\n# Real\n\n> TLDR.\n\n## S\nbody\n' > "$D/fenced-heading.md"
  expect_silent fenced-heading "$D/fenced-heading.md"
  # stub with all 5 sections + TL;DR -> silent
  printf -- '---\nx: 1\n---\n# T\n\n> What this covers.\n\n## Key Entry Points\n*Stub — will be populated by the draft skill.*\n\n## Patterns & Conventions\n*Stub — will be populated by the draft skill.*\n\n## Gotchas\n*Stub — will be populated by the draft skill.*\n\n## Dependencies & Context\n*Stub — will be populated by the draft skill.*\n\n## Links\n*Stub — will be populated by the draft skill.*\n' > "$D/stub-good.md"
  expect_silent stub-good "$D/stub-good.md"
  # stub missing a section -> warn
  printf -- '---\nx: 1\n---\n# T\n\n> TLDR.\n\n## Key Entry Points\n*Stub — will be populated by the draft skill.*\n' > "$D/stub-short.md"
  expect_warn stub-short "$D/stub-short.md"
  # mature topic QUOTING the marker inside a fence -> treated mature, TL;DR present -> silent
  printf -- '---\nx: 1\n---\n# T\n\n> TLDR.\n\n## About templates\n```markdown\n*Stub — will be populated by the draft skill.*\n```\n' > "$D/fenced-marker.md"
  expect_silent fenced-marker "$D/fenced-marker.md"
  # STATUS.md always silent
  printf -- 'anything' > "$D/STATUS.md"
  expect_silent status-md "$D/STATUS.md"
  # custom docs_dir via .scribe.yml, repo-relative path
  mkdir -p "$TMP/repo/docs/ai"; printf 'output:\n  docs_dir: "docs/ai"\n' > "$TMP/repo/.scribe.yml"
  printf -- '---\nx: 1\n---\nno heading\n' > "$TMP/repo/docs/ai/t.md"
  out="$(cd "$TMP/repo" && printf '{"tool_input":{"file_path":"docs/ai/t.md"}}' | env -u CLAUDE_PROJECT_DIR bash "$HOOK" 2>"$TMP/rel.err")"; rc=$?
  [ $rc -eq 0 ] && [ ! -s "$TMP/rel.err" ] && printf '%s' "$out" | grep -q WARNING \
    && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL[$MODE]: custom-docs-dir-relative rc=$rc"; }
  rm "$TMP/repo/.scribe.yml"
  # stub with all 5 sections but NO TL;DR -> warn (stub TL;DR enforcement is new)
  printf -- '---\nx: 1\n---\n# T\n\n## Key Entry Points\n*Stub — will be populated by the draft skill.*\n\n## Patterns & Conventions\n*Stub — will be populated by the draft skill.*\n\n## Gotchas\n*Stub — will be populated by the draft skill.*\n\n## Dependencies & Context\n*Stub — will be populated by the draft skill.*\n\n## Links\n*Stub — will be populated by the draft skill.*\n' > "$D/stub-no-tldr.md"
  expect_warn stub-no-tldr "$D/stub-no-tldr.md"
  # custom docs_dir again, ABSOLUTE path this time
  printf 'output:\n  docs_dir: "docs/ai"\n' > "$TMP/repo/.scribe.yml"
  expect_warn custom-docs-dir-absolute "$TMP/repo/docs/ai/t.md"
  rm "$TMP/repo/.scribe.yml"
  # leading-/ docs_dir value: exact path prefix semantics
  printf 'output:\n  docs_dir: "%s/docs/ai"\n' "$TMP/repo" > "$TMP/repo/.scribe.yml"
  expect_warn leading-slash-docs-dir "$TMP/repo/docs/ai/t.md"
  rm "$TMP/repo/.scribe.yml"
  # (envelope assertion now lives inside expect_warn — no separate case needed)
  # malformed JSON input -> silent on stdout AND stderr, exit 0
  out="$(printf 'not json' | bash "$HOOK" 2>"$TMP/mj.err")"; rc=$?
  [ $rc -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP/mj.err" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL[$MODE]: malformed-json rc=$rc"; }
  # non-docs file silent
  printf 'x' > "$TMP/repo/other.md"; expect_silent non-docs "$TMP/repo/other.md"

  # --- Additional required cases ---

  # 1. frontmatter only, no heading, no body -> stub tier (body empty) -> warn (5 sections + TL;DR missing)
  printf -- '---\nx: 1\n---\n' > "$D/empty-body.md"
  expect_warn empty-body "$D/empty-body.md"

  # 2. mature topic, marker mentioned mid-sentence outside a fence (anchoring test) -> silent
  printf -- '---\nx: 1\n---\n# T\n\n> TLDR.\n\n## Notes\nSee how *Stub — will be populated* text renders inline.\n' > "$D/marker-midline.md"
  expect_silent marker-midline "$D/marker-midline.md"

  # 3. marker inside a ~~~ fence -> mature, TL;DR present -> silent
  printf -- '---\nx: 1\n---\n# T\n\n> TLDR.\n\n## About templates\n~~~markdown\n*Stub — will be populated by the draft skill.*\n~~~\n' > "$D/tilde-fence.md"
  expect_silent tilde-fence "$D/tilde-fence.md"

  # 4. a "# comment" line inside YAML frontmatter must not satisfy the heading anchor -> warn
  printf -- '---\n# comment\nx: 1\n---\nno heading here\n' > "$D/frontmatter-comment.md"
  expect_warn frontmatter-comment "$D/frontmatter-comment.md"

  # 5. custom docs_dir configured to docs/ai; a bad file at docs/agents/ is now OUT of scope -> silent
  printf 'output:\n  docs_dir: "docs/ai"\n' > "$TMP/repo/.scribe.yml"
  printf -- '---\nx: 1\n---\nno heading\n' > "$D/negative-scope.md"
  expect_silent negative-docs-dir "$D/negative-scope.md"
  rm "$TMP/repo/.scribe.yml"

  # 6. absolute docs_dir configured; a path that merely CONTAINS the value as a substring must not match -> silent
  printf 'output:\n  docs_dir: "/scribetest/docs/ai"\n' > "$TMP/repo/.scribe.yml"
  mkdir -p "$TMP/repo/decoy/scribetest/docs/ai"
  printf -- '---\nx: 1\n---\nno heading\n' > "$TMP/repo/decoy/scribetest/docs/ai/t.md"
  expect_silent leading-slash-not-prefix "$TMP/repo/decoy/scribetest/docs/ai/t.md"
  rm "$TMP/repo/.scribe.yml"

  # 7. TOP-LEVEL docs_dir (outside output: block) must be ignored; default dir still validated -> warn
  printf 'docs_dir: "docs/ai"\noutput:\n  x: 1\n' > "$TMP/repo/.scribe.yml"
  printf -- '---\nx: 1\n---\nno heading\n' > "$D/top-level-docs-dir.md"
  expect_warn top-level-docs-dir-ignored "$D/top-level-docs-dir.md"
  rm "$TMP/repo/.scribe.yml"

  # 8. output: block with unquoted docs_dir + trailing comment -> still parsed, bad file in docs/ai/ -> warn
  printf 'output:\n  docs_dir: docs/ai   # comment\n' > "$TMP/repo/.scribe.yml"
  printf -- '---\nx: 1\n---\nno heading\n' > "$TMP/repo/docs/ai/t2.md"
  expect_warn unquoted-comment-docs-dir "$TMP/repo/docs/ai/t2.md"
  rm "$TMP/repo/.scribe.yml"

  # 9. well-formed JSON without a file_path key -> silent on both streams
  out="$(printf '{"tool_input":{}}' | bash "$HOOK" 2>"$TMP/nfp.err")"; rc=$?
  [ $rc -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP/nfp.err" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL[$MODE]: no-file-path rc=$rc"; }

  # 10. file_path pointing at a file that does not exist -> silent on both streams
  expect_silent nonexistent-file "$D/does-not-exist.md"

  # --- fix-verification cases (review round 1) ---

  # Windows-native, JSON-escaped file_path (real \\ pairs in the wire payload, not a
  # forward-slash path in disguise) must still resolve and warn. Requires a genuine
  # Windows-style absolute path string, built via cygpath from the same on-disk file
  # the POSIX-path cases already use, so the fixture actually exists at that path.
  printf -- '---\nx: 1\n---\nno heading\n' > "$D/win-style.md"
  if command -v cygpath >/dev/null 2>&1; then
    win_path="$(cygpath -w "$D/win-style.md" 2>/dev/null)"
    win_escaped="$(printf '%s' "$win_path" | sed 's/\\/\\\\/g')"
    out="$(printf '{"tool_input":{"file_path":"%s"}}' "$win_escaped" | bash "$HOOK" 2>"$TMP/win.err")"; rc=$?
    if [ $rc -eq 0 ] && [ ! -s "$TMP/win.err" ] && printf '%s' "$out" | grep -q '"systemMessage".*WARNING'; then
      PASS=$((PASS+1))
    else
      FAIL=$((FAIL+1)); echo "FAIL[$MODE]: windows-native-json-escaped-path rc=$rc -> $out"
    fi
  else
    echo "SKIP[$MODE]: windows-native-json-escaped-path (cygpath unavailable on this machine)"
  fi

  # requirement 7 (discriminating): the removed "Fix before proceeding" clause must
  # not reappear in the advisory text.
  out="$(invoke "$D/no-heading.md" 2>"$TMP/req7a.err")"; rc=$?
  if [ $rc -eq 0 ] && [ ! -s "$TMP/req7a.err" ] && ! printf '%s' "$out" | grep -q 'Fix before proceeding'; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL[$MODE]: no-fix-before-proceeding-clause rc=$rc -> $out"
  fi

  # requirement 7 (discriminating): a mature-tier warning lists only the TL;DR
  # element, never the 5 skeleton sections.
  out="$(invoke "$D/no-heading.md" 2>"$TMP/req7b.err")"; rc=$?
  if [ $rc -eq 0 ] && [ ! -s "$TMP/req7b.err" ] \
     && printf '%s' "$out" | grep -q 'TL;DR blockquote' \
     && ! printf '%s' "$out" | grep -q 'Key Entry Points'; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL[$MODE]: mature-warning-lists-only-tldr rc=$rc -> $out"
  fi

  # --- fix-verification cases (review round 2) ---

  # F15 (discriminating): a CRLF stub file must validate exactly like its LF twin.
  # Without the awk-side \r strip, the frontmatter anchor ($0 == "---") and every
  # section equality test ("## " s1 ...) fail on the trailing \r, so this
  # complete stub would be reported as missing all five sections.
  printf -- '---\r\nx: 1\r\n---\r\n# T\r\n\r\n> What this covers.\r\n\r\n## Key Entry Points\r\n*Stub — will be populated by the draft skill.*\r\n\r\n## Patterns & Conventions\r\n*Stub — will be populated by the draft skill.*\r\n\r\n## Gotchas\r\n*Stub — will be populated by the draft skill.*\r\n\r\n## Dependencies & Context\r\n*Stub — will be populated by the draft skill.*\r\n\r\n## Links\r\n*Stub — will be populated by the draft skill.*\r\n' > "$D/crlf-stub-good.md"
  expect_silent crlf-stub-good "$D/crlf-stub-good.md"

  # F16 (discriminating): a body made entirely of fenced content is body content,
  # so the file takes the mature branch. Its only missing element is the TL;DR —
  # the five skeleton sections must not be listed, which is what happened while
  # fence lines were consumed before body_nonblank was set.
  printf -- '---\nx: 1\n---\n```go\nfunc main() {}\n```\n' > "$D/fence-only-body.md"
  out="$(invoke "$D/fence-only-body.md" 2>"$TMP/f16.err")"; rc=$?
  if [ $rc -eq 0 ] && [ ! -s "$TMP/f16.err" ] \
     && printf '%s' "$out" | grep -q 'TL;DR blockquote' \
     && ! printf '%s' "$out" | grep -q 'Key Entry Points'; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL[$MODE]: fence-only-body-is-mature rc=$rc -> $out"
  fi

  # --- fix-verification cases (gate round 3) ---

  # F6 (discriminating): a docs_dir carrying a trailing slash must normalize to
  # the same value the orchestrator uses. Without the strip the match patterns
  # double the separator ("*/docs/ai//*.md") and match nothing, so the hook goes
  # silent for every topic in the repo instead of validating them.
  printf 'output:\n  docs_dir: "docs/ai/"\n' > "$TMP/repo/.scribe.yml"
  expect_warn trailing-slash-docs-dir "$TMP/repo/docs/ai/t.md"
  rm "$TMP/repo/.scribe.yml"

  # F7 (discriminating): an `output:` line with a trailing comment must still
  # open the block. Without it `in_output` is never set, docs_dir silently falls
  # back to the default, and this out-of-default file is never validated.
  printf 'output:   # where generated docs go\n  docs_dir: "docs/ai"\n' > "$TMP/repo/.scribe.yml"
  expect_warn output-key-trailing-comment "$TMP/repo/docs/ai/t.md"
  rm "$TMP/repo/.scribe.yml"

  # F16 (discriminating): the element list is built by appending "<name>," per
  # element, so the sentence must not end in ",." once the period is added.
  out="$(invoke "$D/no-heading.md" 2>"$TMP/f16b.err")"; rc=$?
  if [ $rc -eq 0 ] && [ ! -s "$TMP/f16b.err" ] \
     && printf '%s' "$out" | grep -q 'TL;DR blockquote\.' \
     && ! printf '%s' "$out" | grep -q ',\.'; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL[$MODE]: no-dangling-comma-in-warning rc=$rc -> $out"
  fi

  # --- fix-verification cases (gate round 4) ---
  # Every case below fails against the pre-round-4 script; each comment names the
  # pre-fix behaviour it catches. They matter most on the no-jq pass: the jq path
  # already agreed with `.tool_input.file_path`, and that disagreement is exactly
  # what the fallback had to be rebuilt to close.

  # F6a (discriminating): malformed JSON that happens to contain a file_path must
  # be silent. The old pattern-matching fallback never established that the
  # payload was JSON at all, so it warned on input no parser would have accepted.
  out="$(printf '{"tool_input": {"file_path": "%s"' "$D/no-heading.md" | bash "$HOOK" 2>"$TMP/g4a.err")"; rc=$?
  [ $rc -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP/g4a.err" ] && PASS=$((PASS+1)) \
    || { FAIL=$((FAIL+1)); echo "FAIL[$MODE]: malformed-json-carrying-file-path rc=$rc -> $out"; }

  # F6a' (discriminating): structurally *nearly* valid input is still malformed.
  # A trailing comma is the shape a pattern match is least likely to notice and
  # the one the first cut of the scanner also let through; no JSON parser accepts
  # it, so neither may the hook.
  out="$(printf '{"tool_input":{"file_path":"%s",}}' "$D/no-heading.md" | bash "$HOOK" 2>"$TMP/g4a2.err")"; rc=$?
  [ $rc -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP/g4a2.err" ] && PASS=$((PASS+1)) \
    || { FAIL=$((FAIL+1)); echo "FAIL[$MODE]: trailing-comma-json rc=$rc -> $out"; }

  # F6a'' (discriminating): the separators are not optional. A missing ":" after a
  # key and a missing "," between members both left the scanner walking a payload
  # no JSON parser accepts, and it acted on the file_path it found there.
  out="$(printf '{"tool_input" {"file_path":"%s"}}' "$D/no-heading.md" | bash "$HOOK" 2>"$TMP/g4a3.err")"; rc=$?
  [ $rc -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP/g4a3.err" ] && PASS=$((PASS+1)) \
    || { FAIL=$((FAIL+1)); echo "FAIL[$MODE]: missing-colon-after-key rc=$rc -> $out"; }
  out="$(printf '{"tool_input":{"file_path":"%s"} "other":1}' "$D/no-heading.md" | bash "$HOOK" 2>"$TMP/g4a4.err")"; rc=$?
  [ $rc -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP/g4a4.err" ] && PASS=$((PASS+1)) \
    || { FAIL=$((FAIL+1)); echo "FAIL[$MODE]: missing-comma-between-members rc=$rc -> $out"; }

  # F6b (discriminating): a top-level "file_path" with no tool_input is not
  # `.tool_input.file_path` and must be ignored. The old fallback matched the key
  # anywhere in the payload and validated the file regardless of its position.
  out="$(printf '{"file_path": "%s"}' "$D/no-heading.md" | bash "$HOOK" 2>"$TMP/g4b.err")"; rc=$?
  [ $rc -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP/g4b.err" ] && PASS=$((PASS+1)) \
    || { FAIL=$((FAIL+1)); echo "FAIL[$MODE]: top-level-file-path-only rc=$rc -> $out"; }

  # F6c (discriminating): a second "file_path" elsewhere in the payload must not
  # disturb selection. The old fallback concatenated both matches into one
  # newline-joined value, which failed [ -f ] and silently disabled validation —
  # a real Write payload carrying a tool_response echo would have gone unchecked.
  out="$(printf '{"tool_input":{"file_path":"%s"},"tool_response":{"file_path":"%s"}}' "$D/no-heading.md" "$D/good.md" | bash "$HOOK" 2>"$TMP/g4c.err")"; rc=$?
  if [ $rc -eq 0 ] && [ ! -s "$TMP/g4c.err" ] \
     && printf '%s' "$out" | grep -q '"systemMessage".*WARNING' \
     && printf '%s' "$out" | grep -q 'no-heading\.md'; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL[$MODE]: competing-file-path-keys rc=$rc -> $out"
  fi

  # F7 (discriminating): a Windows-native absolute docs_dir must match a
  # Windows-native incoming path. Only file_path was normalized before, so the
  # configured "C:\...\docs\ai" never equalled the incoming "C:/.../docs/ai" and
  # fell into the relative branch, where nothing matched — on Windows every topic
  # write bypassed the hook.
  if command -v cygpath >/dev/null 2>&1; then
    win_docs="$(cygpath -w "$TMP/repo/docs/ai" 2>/dev/null)"
    win_topic="$(cygpath -w "$TMP/repo/docs/ai/t.md" 2>/dev/null)"
    printf 'output:\n  docs_dir: "%s"\n' "$(printf '%s' "$win_docs" | sed 's/\\/\\\\/g')" > "$TMP/repo/.scribe.yml"
    win_topic_escaped="$(printf '%s' "$win_topic" | sed 's/\\/\\\\/g')"
    out="$(printf '{"tool_input":{"file_path":"%s"}}' "$win_topic_escaped" | bash "$HOOK" 2>"$TMP/g4d.err")"; rc=$?
    if [ $rc -eq 0 ] && [ ! -s "$TMP/g4d.err" ] && printf '%s' "$out" | grep -q '"systemMessage".*WARNING'; then
      PASS=$((PASS+1))
    else
      FAIL=$((FAIL+1)); echo "FAIL[$MODE]: windows-native-absolute-docs-dir rc=$rc -> $out"
    fi
    rm "$TMP/repo/.scribe.yml"
  else
    echo "SKIP[$MODE]: windows-native-absolute-docs-dir (cygpath unavailable on this machine)"
  fi

  # F8a (discriminating): a "#" inside a quoted scalar is part of the value, not
  # a comment. Cutting at it left docs_dir="docs", which widened validation to
  # every unrelated tree under docs/ — this out-of-scope file used to warn.
  printf 'output:\n  docs_dir: "docs/#agents"\n' > "$TMP/repo/.scribe.yml"
  mkdir -p "$TMP/repo/docs/other" "$TMP/repo/docs/#agents"
  printf -- '---\nx: 1\n---\nno heading\n' > "$TMP/repo/docs/other/x.md"
  expect_silent quoted-hash-docs-dir-no-widening "$TMP/repo/docs/other/x.md"
  # companion (not discriminating — it warned before the fix too): the configured
  # value is still the one actually honoured.
  printf -- '---\nx: 1\n---\nno heading\n' > "$TMP/repo/docs/#agents/t.md"
  expect_warn quoted-hash-docs-dir-honoured "$TMP/repo/docs/#agents/t.md"
  rm "$TMP/repo/.scribe.yml"

  # F8b (discriminating): docs_dir is a direct child of output:, never a
  # grandchild. Any indented descendant used to be accepted, so this nested key
  # moved validation to docs/ai and this default-directory file went unchecked.
  printf 'output:\n  nested:\n    docs_dir: "docs/ai"\n' > "$TMP/repo/.scribe.yml"
  printf -- '---\nx: 1\n---\nno heading\n' > "$D/nested-default.md"
  expect_warn nested-docs-dir-does-not-override-default "$D/nested-default.md"
  rm "$TMP/repo/.scribe.yml"

  # --- fix-verification cases (gate round 5) ---

  # F13 (discriminating): a UTF-8 BOM sits in front of line 1, so the
  # frontmatter anchor ($0 == "---") failed and the frontmatter block was parsed
  # as body — which is how case 4 above fails in reverse: the `#` comment inside
  # the frontmatter became the H1 anchor, the `x: 1` after it was judged as the
  # TL;DR position, and this correctly-structured file was reported as missing
  # its blockquote. Windows editors write a BOM routinely. The plain
  # BOM-plus-frontmatter shape is deliberately NOT used here: with nothing in
  # the frontmatter that the body grammar reacts to, misparsing it changes no
  # verdict and the case cannot fail.
  printf -- '\357\273\277---\n# yaml comment\nx: 1\n---\n# T\n\n> What this covers.\n\n## Notes\nbody\n' > "$D/bom-frontmatter-comment.md"
  expect_silent bom-frontmatter-comment "$D/bom-frontmatter-comment.md"

  # F13 (discriminating): the same file with CRLF endings — a Windows editor
  # writes both marks, and neither strip may depend on the other's absence.
  printf -- '\357\273\277---\r\n# yaml comment\r\nx: 1\r\n---\r\n# T\r\n\r\n> What this covers.\r\n\r\n## Notes\r\nbody\r\n' > "$D/bom-crlf-frontmatter-comment.md"
  expect_silent bom-crlf-frontmatter-comment "$D/bom-crlf-frontmatter-comment.md"

  # F13 companion (not discriminating — it warned before the fix too): the strip
  # must not make the hook go blind. A BOM-prefixed file genuinely missing its
  # TL;DR still warns.
  printf -- '\357\273\277---\nx: 1\n---\n# T\n\nintro with no blockquote\n' > "$D/bom-no-tldr.md"
  expect_warn bom-no-tldr "$D/bom-no-tldr.md"

  # --- fix-verification cases (gate round 6) ---

  # F5 (discriminating): the warning envelope is assembled by interpolating
  # $file_path into a JSON string, so a path carrying a double quote used to
  # close that string early and emit a payload no JSON consumer can read — the
  # host would drop the warning, or worse, read the tail of the path as further
  # keys. Both cases below assert the escaped spelling in the output, which is
  # the observable form of "the envelope is still one well-formed JSON string".
  # Guarded because the double-quote case cannot exist on a filesystem that
  # rejects the character (native Win32 does; the MSYS/Cygwin layer this plugin
  # is developed on does not).
  quote_topic="$D/qu\"ote.md"
  if { printf -- '---\nx: 1\n---\nno heading\n' > "$quote_topic"; } 2>/dev/null && [ -f "$quote_topic" ]; then
    quote_payload="$(printf '%s' "$quote_topic" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    out="$(printf '{"tool_input":{"file_path":"%s"}}' "$quote_payload" | bash "$HOOK" 2>"$TMP/g6a.err")"; rc=$?
    if [ $rc -eq 0 ] && [ ! -s "$TMP/g6a.err" ] \
       && printf '%s' "$out" | grep -q '"systemMessage".*WARNING' \
       && printf '%s' "$out" | grep -qF 'qu\"ote.md'; then
      PASS=$((PASS+1))
    else
      FAIL=$((FAIL+1)); echo "FAIL[$MODE]: quote-in-path-escaped-in-envelope rc=$rc -> $out"
    fi
  else
    echo "SKIP[$MODE]: quote-in-path-escaped-in-envelope (this filesystem rejects '\"' in a filename)"
  fi

  # F5, second half (discriminating on a POSIX filesystem; SKIPped under
  # MSYS/Cygwin and on native Windows, both of which reserve the character):
  # a lone backslash is not a legal JSON escape either, and normalize_path only
  # rewrites separators for drive-letter and UNC paths — a POSIX path keeps the
  # character verbatim. It must be doubled in the envelope.
  backslash_topic="$D/back\\slash.md"
  if { printf -- '---\nx: 1\n---\nno heading\n' > "$backslash_topic"; } 2>/dev/null && [ -f "$backslash_topic" ]; then
    backslash_payload="$(printf '%s' "$backslash_topic" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    out="$(printf '{"tool_input":{"file_path":"%s"}}' "$backslash_payload" | bash "$HOOK" 2>"$TMP/g6b.err")"; rc=$?
    if [ $rc -eq 0 ] && [ ! -s "$TMP/g6b.err" ] \
       && printf '%s' "$out" | grep -q '"systemMessage".*WARNING' \
       && printf '%s' "$out" | grep -qF 'back\\slash.md'; then
      PASS=$((PASS+1))
    else
      FAIL=$((FAIL+1)); echo "FAIL[$MODE]: backslash-in-path-escaped-in-envelope rc=$rc -> $out"
    fi
  else
    echo "SKIP[$MODE]: backslash-in-path-escaped-in-envelope (this filesystem rejects '\\' in a filename)"
  fi

  # F11 (discriminating): ``` and ~~~ are not interchangeable — only the marker
  # that opened a fence may close it. While both toggled one flag, the ``` line
  # inside this ~~~ block closed it, the stub marker below became visible, the
  # file took the stub branch, and this mature topic was reported as missing all
  # five skeleton sections.
  printf -- '---\nx: 1\n---\n# T\n\n> TLDR.\n\n## About fences\n~~~markdown\n```\n*Stub — will be populated by the draft skill.*\n```\n~~~\n' > "$D/mixed-fence.md"
  expect_silent mixed-fence-markers "$D/mixed-fence.md"

  # --- fix-verification cases (gate round 8) ---

  # BUG-07 (discriminating): a fence opener is a non-blank line, so it occupies
  # the TL;DR position. This topic's first post-H1 content is a code fence and
  # its blockquote only appears later; under the old fence-skipping reading the
  # file passed the positional check outright, with no blockquote in that
  # position at all. It is a mature topic (non-empty body, no marker), so the
  # warning must name the TL;DR alone and never the five skeleton sections.
  printf -- '---\nx: 1\n---\n# Topic\n\n```go\nfunc main() {}\n```\n\n> Blockquote, but not first.\n\n## Notes\nbody\n' > "$D/fence-first.md"
  out="$(invoke "$D/fence-first.md" 2>"$TMP/g8a.err")"; rc=$?
  if [ $rc -eq 0 ] && [ ! -s "$TMP/g8a.err" ] \
     && printf '%s' "$out" | grep -q 'TL;DR blockquote' \
     && ! printf '%s' "$out" | grep -q 'Key Entry Points'; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL[$MODE]: fence-first-fails-tldr rc=$rc -> $out"
  fi

  # BUG-07 companion (not discriminating — silent before the fix too): a fence
  # BELOW the blockquote is still invisible to the check.
  printf -- '---\nx: 1\n---\n# Topic\n\n> TLDR first.\n\n```go\nfunc main() {}\n```\n' > "$D/fence-after-tldr.md"
  expect_silent fence-after-tldr "$D/fence-after-tldr.md"

  # BUG-08: a valid JSON \uXXXX escape in the path, with the real file present
  # on disk under its decoded name. Discriminating on rungs 1-2, which decode it
  # and validate the file. On rung 3 the scanner leaves the escape literal, the
  # [ -f ] test fails and the hook no-ops — that is the awk rung's named gap,
  # asserted here as a gap rather than left to be rediscovered. Guarded: the
  # fixture needs a filesystem that accepts the character.
  unicode_topic="$D/café.md"
  if { printf -- '---\nx: 1\n---\nno heading\n' > "$unicode_topic"; } 2>/dev/null && [ -f "$unicode_topic" ]; then
    # Single-quoted so the shell leaves "é" as six literal characters, and
    # printf '%s' passes it as data rather than as a format string — the payload
    # must reach the hook carrying the escape, not a pre-decoded é.
    unicode_payload='{"tool_input":{"file_path":"'"$D"'/caf\u00e9.md"}}'
    out="$(printf '%s' "$unicode_payload" | bash "$HOOK" 2>"$TMP/g8b.err")"; rc=$?
    if [ "$RUNG" = "awk" ]; then
      [ $rc -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP/g8b.err" ] && PASS=$((PASS+1)) \
        || { FAIL=$((FAIL+1)); echo "FAIL[$MODE]: unicode-escape-path-gap-on-awk-rung rc=$rc -> $out"; }
    elif [ $rc -eq 0 ] && [ ! -s "$TMP/g8b.err" ] && printf '%s' "$out" | grep -q '"systemMessage".*WARNING'; then
      PASS=$((PASS+1))
    else
      FAIL=$((FAIL+1)); echo "FAIL[$MODE]: unicode-escape-path-decoded rc=$rc -> $out"
    fi
    # companion (not discriminating): the same file addressed by a literal UTF-8
    # path warns on every rung, so the gap above is about \uXXXX decoding alone
    # and not about non-ASCII paths in general.
    expect_warn unicode-literal-path "$unicode_topic"
  else
    echo "SKIP[$MODE]: unicode-escape-path (this filesystem rejects the fixture name)"
  fi

  # BUG-11 (discriminating): the scanner claimed to reject malformed JSON while
  # accepting escape sequences JSON does not define and raw control characters
  # inside strings — so rung 3 acted on payloads jq and python both throw out.
  # Both payloads carry a VALID file_path pointing at a file that fails
  # validation, so a rung that wrongly accepts them warns and is caught here;
  # the offending text sits in a sibling key.
  out="$(printf '{"tool_input":{"file_path":"%s","note":"a\\qb"}}' "$D/no-heading.md" | bash "$HOOK" 2>"$TMP/g8c.err")"; rc=$?
  [ $rc -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP/g8c.err" ] && PASS=$((PASS+1)) \
    || { FAIL=$((FAIL+1)); echo "FAIL[$MODE]: invalid-escape-rejected rc=$rc -> $out"; }
  out="$(printf '{"tool_input":{"file_path":"%s","note":"a\001b"}}' "$D/no-heading.md" | bash "$HOOK" 2>"$TMP/g8d.err")"; rc=$?
  [ $rc -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP/g8d.err" ] && PASS=$((PASS+1)) \
    || { FAIL=$((FAIL+1)); echo "FAIL[$MODE]: raw-control-char-rejected rc=$rc -> $out"; }

  # --- fix-verification cases (gate round 8, follow-up) ---

  # R3 (discriminating on rung 3): a duplicated .tool_input.file_path resolves to
  # its LAST occurrence on every rung. jq and python have always done that; the
  # scanner used to refuse the payload as ambiguous, so rung 3 silently skipped
  # validation on input rungs 1 and 2 acted on. Both directions are asserted, so
  # the case proves "the last one" rather than merely "one of them":
  #   good then bad -> warns, and the warning names the bad file;
  #   bad then good -> silent, because the good file passes validation.
  out="$(printf '{"tool_input":{"file_path":"%s","file_path":"%s"}}' "$D/good.md" "$D/no-heading.md" | bash "$HOOK" 2>"$TMP/g8e.err")"; rc=$?
  if [ $rc -eq 0 ] && [ ! -s "$TMP/g8e.err" ] \
     && printf '%s' "$out" | grep -q '"systemMessage".*WARNING' \
     && printf '%s' "$out" | grep -q 'no-heading\.md'; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL[$MODE]: duplicate-file-path-takes-last rc=$rc -> $out"
  fi
  out="$(printf '{"tool_input":{"file_path":"%s","file_path":"%s"}}' "$D/no-heading.md" "$D/good.md" | bash "$HOOK" 2>"$TMP/g8f.err")"; rc=$?
  [ $rc -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP/g8f.err" ] && PASS=$((PASS+1)) \
    || { FAIL=$((FAIL+1)); echo "FAIL[$MODE]: duplicate-file-path-last-is-valid rc=$rc -> $out"; }

  # --- fix-verification cases (gate round 10) ---

  # F6 (discriminating): a docs_dir carrying a leading "./" must normalize to the
  # same value the orchestrator uses — 12a's link matching already strips it.
  # Without the strip the match patterns keep the segment ("*/./docs/ai/*.md",
  # "./docs/ai/*.md"), no incoming path carries a "/./", and the hook goes silent
  # repo-wide while the orchestrator, which tolerates the prefix, keeps working —
  # the same two-components-disagree failure the trailing-slash case above covers.
  printf 'output:\n  docs_dir: "./docs/ai"\n' > "$TMP/repo/.scribe.yml"
  expect_warn dot-slash-docs-dir "$TMP/repo/docs/ai/t.md"
  rm "$TMP/repo/.scribe.yml"

  # F6 companion (discriminating): both marks at once. Stripping only one leaves
  # the other, so neither strip may depend on the other's absence.
  printf 'output:\n  docs_dir: "./docs/ai/"\n' > "$TMP/repo/.scribe.yml"
  expect_warn dot-slash-and-trailing-slash-docs-dir "$TMP/repo/docs/ai/t.md"
  rm "$TMP/repo/.scribe.yml"

}

# --- drive the case list once per extraction rung (see the hook's header) ---
# Three overrides, but a machine can only exercise the rungs whose tool it has:
# resolve which rung each pass actually reaches and print that, rather than
# claiming three distinct parsers ran when two of the passes hit the same one.
have_jq=0; command -v jq >/dev/null 2>&1 && have_jq=1
have_python=0
for cand in python3 python py; do
  command -v "$cand" >/dev/null 2>&1 && { have_python=1; break; }
done

if [ "$have_jq" -eq 1 ]; then pass1_rung="jq"
elif [ "$have_python" -eq 1 ]; then pass1_rung="python"
else pass1_rung="awk"; fi
if [ "$have_python" -eq 1 ]; then pass2_rung="python"; else pass2_rung="awk"; fi

MODE="default"; RUNG="$pass1_rung"; export SCRIBE_NO_JQ= SCRIBE_NO_PYTHON=
echo "=== pass 1/3: no overrides -> rung reached: $pass1_rung ==="
run_cases

MODE="no-jq"; RUNG="$pass2_rung"; export SCRIBE_NO_JQ=1 SCRIBE_NO_PYTHON=
echo "=== pass 2/3: SCRIBE_NO_JQ=1 -> rung reached: $pass2_rung ==="
run_cases

MODE="no-jq-no-python"; RUNG="awk"; export SCRIBE_NO_JQ=1 SCRIBE_NO_PYTHON=1
echo "=== pass 3/3: SCRIBE_NO_JQ=1 SCRIBE_NO_PYTHON=1 -> rung reached: awk JSON scanner, forced ==="
run_cases

echo "--- rungs exercised here: pass1=$pass1_rung pass2=$pass2_rung pass3=awk"
[ "$have_jq" -eq 1 ] || echo "--- jq is not installed on this machine, so the jq rung was never exercised"
[ "$have_python" -eq 1 ] || echo "--- no python interpreter on this machine, so the python rung was never exercised"
echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
