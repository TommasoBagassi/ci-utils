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
  if [ $rc -eq 0 ] && [ ! -s "$TMP/err" ] && printf '%s' "$out" | grep -q '"systemMessage".*WARNING'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL(want-warn): $1 rc=$rc"; fi
}
expect_silent() { # $1=name $2=path — asserts empty stdout, clean stderr, exit 0
  out="$(invoke "$2" 2>"$TMP/err")"; rc=$?
  if [ $rc -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP/err" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL(want-silent): $1 rc=$rc -> $out"; fi
}

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
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: custom-docs-dir-relative rc=$rc"; }
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
[ $rc -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP/mj.err" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: malformed-json rc=$rc"; }
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
[ $rc -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP/nfp.err" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: no-file-path rc=$rc"; }

# 10. file_path pointing at a file that does not exist -> silent on both streams
expect_silent nonexistent-file "$D/does-not-exist.md"

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
