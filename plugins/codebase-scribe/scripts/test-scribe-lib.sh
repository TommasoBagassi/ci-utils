#!/bin/bash
# Test harness for scribe-lib.py. Run from anywhere: bash test-scribe-lib.sh
set -u
LIB="$(cd "$(dirname "$0")" && pwd)/scribe-lib.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

python_bin=""
for cand in python3 python py; do
  command -v "$cand" >/dev/null 2>&1 || continue
  if [ "$cand" = "py" ]; then
    if "$cand" -3 -c 'import sys' >/dev/null 2>&1; then python_bin="$cand -3"; break; fi
  else
    if "$cand" -c 'import sys' >/dev/null 2>&1; then python_bin="$cand"; break; fi
  fi
done
if [ -z "$python_bin" ]; then
  echo "FAIL: no working Python interpreter found (tried python3, python, py -3)"
  exit 1
fi

lib() { $python_bin "$LIB" "$@"; }

expect() { # $1=name $2=expected stdout $3=expected exit code $4...=args to scribe-lib.py
  local name="$1" want="$2" wantrc="$3"; shift 3
  local out rc
  out="$(lib "$@" 2>/dev/null)"; rc=$?
  if [ "$out" = "$want" ] && [ "$rc" -eq "$wantrc" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $name -- want [$want] rc=$wantrc, got [$out] rc=$rc"
  fi
}

# --- shared parsing rules -------------------------------------------------
# The "## Fake" heading sits INSIDE frontmatter, so it is only invisible if the
# BOM / CRLF handling let the frontmatter block be recognised at all.
printf -- '\xef\xbb\xbf---\n## Fake\n---\n## Alpha\n' > "$TMP/bom.md"
expect bom-tolerated $'2\talpha\tAlpha' 0 sections "$TMP/bom.md"

printf -- '---\r\n## Fake\r\n---\r\n## Alpha\r\n' > "$TMP/crlf.md"
expect crlf-tolerated $'2\talpha\tAlpha' 0 sections "$TMP/crlf.md"

printf -- '---\nx: 1\n---\n## Real\n```\n## Fenced\n```\n## Other\n' > "$TMP/fence.md"
expect fenced-heading-invisible $'2\treal\tReal\n2\tother\tOther' 0 sections "$TMP/fence.md"

# A ``` line quoted inside a ~~~ block must not close that block.
printf -- '---\nx: 1\n---\n~~~\n```\n## Hidden\n~~~\n## Visible\n' > "$TMP/pair.md"
expect fence-marker-pairing $'2\tvisible\tVisible' 0 sections "$TMP/pair.md"

# --- sections -------------------------------------------------------------
printf -- '---\nx: 1\n---\n### Orphan\n## Patterns & Conventions\n### Sub Thing\n' > "$TMP/nested.md"
expect sections-level3-scoping \
  $'3\torphan\tOrphan\n3\tpatterns--conventions/sub-thing\tSub Thing' 0 \
  sections "$TMP/nested.md" --level 3
expect sections-level-all \
  $'3\torphan\tOrphan\n2\tpatterns--conventions\tPatterns & Conventions\n3\tpatterns--conventions/sub-thing\tSub Thing' 0 \
  sections "$TMP/nested.md" --level all

# --- slug -----------------------------------------------------------------
expect slug-no-hyphen-dedup patterns--conventions 0 slug "Patterns & Conventions"

# --- tier -----------------------------------------------------------------
printf -- '---\nx: 1\n---\n' > "$TMP/empty.md"
expect tier-empty-body stub 0 tier "$TMP/empty.md"

printf -- '---\nx: 1\n---\n# T\n\n## Key Entry Points\n*Stub — will be populated by the draft skill.*\n' > "$TMP/stub.md"
expect tier-unfenced-marker stub 0 tier "$TMP/stub.md"

printf -- '---\nx: 1\n---\n# T\n\n~~~markdown\n*Stub — will be populated by the draft skill.*\n~~~\n' > "$TMP/fenced-marker.md"
expect tier-fenced-marker-only mature 0 tier "$TMP/fenced-marker.md"

# A body that is nothing but an empty fence still counts as body content.
printf -- '---\nx: 1\n---\n```\n```\n' > "$TMP/only-fence.md"
expect tier-empty-fence-is-content mature 0 tier "$TMP/only-fence.md"

# --- human-input ----------------------------------------------------------
printf -- '---\nx: 1\n---\n## Alpha\n## Beta\n## Gamma\n## Delta\n' > "$TMP/four.md"
expect human-input-two-of-four 50 0 human-input "$TMP/four.md" --slugs "alpha,beta"
expect human-input-distinct 25 0 human-input "$TMP/four.md" --slugs "alpha, alpha"
expect human-input-unknown-slug 0 0 human-input "$TMP/four.md" --slugs "no-such-section"
expect human-input-empty-csv 0 0 human-input "$TMP/four.md" --slugs ""
expect human-input-no-sections 0 0 human-input "$TMP/empty.md" --slugs "alpha"

printf -- '---\nx: 1\n---\n## A1\n## A2\n## A3\n## A4\n## A5\n## A6\n## A7\n## A8\n' > "$TMP/eight.md"
expect human-input-round-half-up 13 0 human-input "$TMP/eight.md" --slugs "a1"

# --- completeness ---------------------------------------------------------
mkdir -p "$TMP/tree/src/a" "$TMP/tree/src/b" "$TMP/tree/src/.git" "$TMP/tree/flat"
echo x > "$TMP/tree/src/a/one.txt"
echo x > "$TMP/tree/src/b/two.txt"
echo x > "$TMP/tree/src/.git/config"
echo x > "$TMP/tree/flat/only-file.txt"
# src/b/two.txt is cited only in FRONTMATTER, which does not count as coverage;
# src/.git must be skipped, or the population would be 3 and the score 33.
printf -- '---\nscan: "src/b/two.txt"\n---\nSee `src/a/one.txt` for details.\n' > "$TMP/tree/doc.md"
printf -- '---\nx: 1\n---\nsrc/a/one.txt and src/b/two.txt are both covered.\n' > "$TMP/tree/doc2.md"
cd "$TMP/tree" || exit 1
expect completeness-half 50 0 completeness doc.md src
expect completeness-watch-union 50 0 completeness doc.md src ./src
expect completeness-full 100 0 completeness doc2.md src
expect completeness-no-subdirs 0 0 completeness doc.md flat
expect completeness-missing-watch 0 0 completeness doc.md no-such-dir
cd "$TMP" || exit 1

# --- validate-sha ---------------------------------------------------------
mkdir -p "$TMP/repo"
cd "$TMP/repo" || exit 1
git init -q . >/dev/null 2>&1
git config user.email test@example.com
git config user.name test
git config core.autocrlf false
echo one > f.txt; git add f.txt; git commit -qm one >/dev/null 2>&1
echo two >> f.txt; git add f.txt; git commit -qm two >/dev/null 2>&1
# Read after the first commit: an unborn HEAD has no resolvable branch name, and
# an empty one here silently leaves the orphan branch below checked out.
orig_branch="$(git rev-parse --abbrev-ref HEAD)"
ancestor_sha="$(git rev-parse HEAD~1)"
git checkout -q --orphan side >/dev/null 2>&1
echo side > s.txt; git add s.txt; git commit -qm side >/dev/null 2>&1
orphan_sha="$(git rev-parse HEAD)"
git checkout -q "$orig_branch" >/dev/null 2>&1
expect sha-empty null 2 validate-sha ""
expect sha-literal-null null 2 validate-sha "null"
expect sha-bad-shape shape 1 validate-sha "ZZZ123"
expect sha-unresolvable unresolvable 1 validate-sha "0123456789abcdef0123456789abcdef01234567"
expect sha-unreachable unreachable 1 validate-sha "$orphan_sha"
expect sha-valid valid 0 validate-sha "$ancestor_sha"
cd "$TMP" || exit 1

# --- classify -------------------------------------------------------------
CD="$TMP/cls"; mkdir -p "$CD"
{
  printf -- '---\nx: 1\n---\n# Topic\n\n> TLDR.\n\n## Alpha\n'
  for i in 1 2 3 4 5; do echo "alpha line $i"; done
  printf -- '\n## Beta\n'
  for i in 1 2 3 4 5; do echo "beta line $i"; done
} > "$CD/current.md"                       # 20 lines, two ## sections
# 2 changed lines => 4 diff lines: under 50% of 20, and tunable against --threshold
sed -e 's/^x: 1$/scan: "abc1234"/' -e 's/^alpha line 3$/alpha line THREE/' "$CD/current.md" > "$CD/snap.md"
sed -e 's/^x: 1$/scan: null/' "$CD/current.md" > "$CD/snap-null.md"
sed -e 's/^x: 1$/scan: ~/' "$CD/current.md" > "$CD/snap-tilde.md"
{ printf -- '---\nscan: "abc1234"\n---\n'; for i in $(seq 1 20); do echo "wholly different $i"; done; } > "$CD/snap-big.md"
: > "$CD/snap-zero.md"
printf 'claim one\nclaim two\n' > "$CD/sc.txt"
printf 'claim one\nclaim two\n' > "$CD/cc.txt"
printf 'claim one\nclaim CHANGED\n' > "$CD/cc-diff.txt"
printf 'Alpha\nBeta\n' > "$CD/sh.txt"
printf 'Alpha\nGamma\n' > "$CD/sh-diff.txt"

classify_case() { # $1=name $2=expected $3=snapshot $4=current-claims $5=snapshot-headings $6=threshold
  expect "$1" "$2" 0 classify "$CD/current.md" --snapshot "$3" \
    --snapshot-claims "$CD/sc.txt" --current-claims "$4" \
    --snapshot-headings "$5" --threshold "$6"
}
classify_case classify-a-no-snapshot   major_rewrite    "$CD/absent.md"     "$CD/cc.txt"      "$CD/sh.txt"      100
classify_case classify-b-zero-bytes    new_draft        "$CD/snap-zero.md"  "$CD/cc.txt"      "$CD/sh.txt"      100
classify_case classify-b-scan-null     new_draft        "$CD/snap-null.md"  "$CD/cc.txt"      "$CD/sh.txt"      100
classify_case classify-b-scan-tilde    new_draft        "$CD/snap-tilde.md" "$CD/cc.txt"      "$CD/sh.txt"      100
classify_case classify-c-major-rewrite major_rewrite    "$CD/snap-big.md"   "$CD/cc.txt"      "$CD/sh.txt"      100
classify_case classify-d-claim-change  claim_change     "$CD/snap.md"       "$CD/cc-diff.txt" "$CD/sh.txt"      100
classify_case classify-e-section-chg   section_change   "$CD/snap.md"       "$CD/cc.txt"      "$CD/sh-diff.txt" 100
classify_case classify-f-large-diff    large_diff       "$CD/snap.md"       "$CD/cc.txt"      "$CD/sh.txt"      1
classify_case classify-g-minor         minor_mechanical "$CD/snap.md"       "$CD/cc.txt"      "$CD/sh.txt"      10
# deleted "---" content lines render as "----" in a unified diff and must count
cat "$CD/snap.md" > "$CD/snap-hr.md"; printf -- '---\n---\n---\n---\n' >> "$CD/snap-hr.md"
classify_case classify-f-hr-deletions  large_diff       "$CD/snap-hr.md"    "$CD/cc.txt"      "$CD/sh.txt"      7
# claims AND headings both differ: rule d wins because the order is strict
classify_case classify-precedence      claim_change     "$CD/snap.md"       "$CD/cc-diff.txt" "$CD/sh-diff.txt" 100
# both claim files missing read as empty, so they are equal
expect classify-missing-claims minor_mechanical 0 classify "$CD/current.md" --snapshot "$CD/snap.md" \
  --snapshot-claims "$CD/gone-a.txt" --current-claims "$CD/gone-b.txt" \
  --snapshot-headings "$CD/sh.txt" --threshold 10

# --- hub-state ------------------------------------------------------------
HB="$TMP/hub"; mkdir -p "$HB"
expect hub-state-absent absent 0 hub-state "$HB/no-such-hub.md"

printf -- '<!-- scribe:managed -->\n# Hub\n' > "$HB/managed.md"
expect hub-state-managed managed 0 hub-state "$HB/managed.md"

printf -- '# Hub\n\n  <!-- scribe:managed:append-only -->\n' > "$HB/append.md"
expect hub-state-append-only append-only 0 hub-state "$HB/append.md"

printf -- '# Hub\n\nNothing here.\n' > "$HB/plain.md"
expect hub-state-unmarked unmarked 0 hub-state "$HB/plain.md"

# A hub that only documents the convention must not be silently adopted.
printf -- '# Hub\n\n```markdown\n<!-- scribe:managed -->\n```\n' > "$HB/fenced.md"
expect hub-state-fenced-marker unmarked 0 hub-state "$HB/fenced.md"

printf -- '# Hub\n\nAdd <!-- scribe:managed --> to opt in.\n' > "$HB/midline.md"
expect hub-state-midline-marker unmarked 0 hub-state "$HB/midline.md"

# append-only is the more restrictive mode, so it wins even when it comes second
printf -- '<!-- scribe:managed -->\n<!-- scribe:managed:append-only -->\n' > "$HB/both.md"
expect hub-state-both-markers append-only 0 hub-state "$HB/both.md"

# --- hub-links ------------------------------------------------------------
printf -- '- [Api](docs/agents/api.md)\n[ref]: docs/agents/ref.md\n' > "$HB/l-basic.md"
expect hub-links-inline-and-reference $'docs/agents/api.md\ndocs/agents/ref.md' 0 \
  hub-links "$HB/l-basic.md" --docs-dir docs/agents

printf -- '- [Old](docs/agents-old/api.md)\n- [X](docs/agentsx)\n' > "$HB/l-sibling.md"
expect hub-links-segment-boundary "" 0 hub-links "$HB/l-sibling.md" --docs-dir docs/agents

printf -- '- [Dot](./docs/agents/dot.md)\n' > "$HB/l-dot.md"
expect hub-links-dot-slash-stripped docs/agents/dot.md 0 \
  hub-links "$HB/l-dot.md" --docs-dir docs/agents

printf -- 'See [a](docs/agents/a.md) and [b](docs/agents/b.md) both.\n' > "$HB/l-two.md"
expect hub-links-two-on-one-line $'docs/agents/a.md\ndocs/agents/b.md' 0 \
  hub-links "$HB/l-two.md" --docs-dir docs/agents

# link matching is defined over the whole file, so fences are not skipped here
printf -- '```\n[Fenced](docs/agents/fenced.md)\n```\n' > "$HB/l-fenced.md"
expect hub-links-fence-not-skipped docs/agents/fenced.md 0 \
  hub-links "$HB/l-fenced.md" --docs-dir docs/agents

expect hub-links-none "" 0 hub-links "$HB/plain.md" --docs-dir docs/agents
expect hub-links-missing-file "" 3 hub-links "$HB/no-such-hub.md" --docs-dir docs/agents

# --- repair-watch-paths ---------------------------------------------------
mkdir -p "$TMP/wp/src/lib" "$TMP/wp/cmd/server"
echo x > "$TMP/wp/cmd/server/main.go"
echo x > "$TMP/wp/top.txt"
cd "$TMP/wp" || exit 1
expect repair-file-widened $'cmd/server\tcmd/server/main.go\tok' 0 \
  repair-watch-paths cmd/server/main.go
expect repair-trailing-slash $'src/lib\tsrc/lib/\tok' 0 repair-watch-paths "src/lib/"
expect repair-backslashes $'src/lib\tsrc\\lib\\\tok' 0 repair-watch-paths 'src\lib\'
expect repair-single-segment-dir $'src\tsrc\tok' 0 repair-watch-paths src
expect repair-single-segment-file $'top.txt\ttop.txt\tok' 0 repair-watch-paths top.txt
expect repair-single-segment-unresolved $'nope\tnope\tunresolved' 0 repair-watch-paths nope
# nothing on the way up exists, so the walk stops at the preserved single segment
expect repair-walks-to-single-segment $'nope\tnope/deep/x.go\tunresolved' 0 \
  repair-watch-paths nope/deep/x.go
# both entries repair to cmd/server; the first occurrence keeps its <original>
expect repair-dedupe-first-wins $'cmd/server\tcmd/server/main.go\tok' 0 \
  repair-watch-paths cmd/server/main.go cmd/server/
expect repair-order-preserved $'src/lib\tsrc/lib\tok\nnope\tnope\tunresolved' 0 \
  repair-watch-paths src/lib nope
expect repair-no-args "" 3 repair-watch-paths
cd "$TMP" || exit 1

# --- operational errors ---------------------------------------------------
expect error-missing-file "" 3 tier "$TMP/no-such-file.md"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
