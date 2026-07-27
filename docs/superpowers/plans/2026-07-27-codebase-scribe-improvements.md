# codebase-scribe Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the accepted spec `docs/superpowers/specs/2026-07-27-codebase-scribe-improvements-design.md` (rev 6.1) — drift-integrity fixes, the two-tier structure contract, the review-agent conversion, provenance durability, the #39 strip, and eval regeneration for the codebase-scribe plugin.

**Architecture:** The plugin is a set of prose instruction files (`commands/codebase-scribe.md`, four `skills/*/SKILL.md`, one agent file to be created) plus a bash PostToolUse hook and per-skill eval suites. Implementation is seven waves, each an independently PR-able unit, in strict order (the spec's §9). Wave 1 is the kiali-blocking bundle and must be complete and internally consistent on its own.

**Tech Stack:** Markdown instruction files; bash (hook); YAML (eval configs, frontmatter schemas); git.

## Global Constraints

- **The spec is the normative source.** Where a task says "per spec §X", the exact wording in `docs/superpowers/specs/2026-07-27-codebase-scribe-improvements-design.md` §X is authoritative and must be transcribed faithfully — the spec was review-gated at that wording. Never paraphrase normative replacement text.
- Baseline: branch `scribe-improvements` on the fork, on top of `f8f0b9a`. All work commits to this branch; one PR per wave, in wave order.
- Never edit any `eval.yaml`, `eval.md`, or `eval/` content except in Task 26 (wave 6). Eval fixtures are excluded from all acceptance greps (spec §6, §8).
- `plugins/codebase-scribe/IMPROVEMENT-REPORT.md` is an uncommitted working doc: never commit it, never delete it before Task 28.
- The kiali completion run is external and waits for wave 3+; nothing in this plan runs against kiali.
- Line references into plugin sources below were verified at baseline; re-locate by quoted text if drift occurred.
- Commit messages: prefix `scribe:`; every commit trailer per repo convention.
- Version stays `1.2.6` in all four manifests until Task 28 (single bump to 1.3.0).

**File inventory (all under `plugins/codebase-scribe/` unless noted):**
- `commands/codebase-scribe.md` — orchestrator ("the command")
- `skills/scribe-discover/SKILL.md`, `skills/scribe-draft/SKILL.md`, `skills/scribe-maintain/SKILL.md`, `skills/scribe-review/SKILL.md` — the skills
- `skills/prompts/review-adversarial.md` — merged into the agent in wave 3, then deleted
- `agents/scribe-review.md` — created in wave 3
- `hooks/doc-validate.sh`, `hooks/hooks.json`
- `README.md`, `.claude-plugin/plugin.json`, `.cursor-plugin/plugin.json`; repo-root `.claude-plugin/marketplace.json`, `.cursor-plugin/marketplace.json`
- `docs/contributing.md` (repo root) — one clause in Task 17

---

## Wave 1 — drift integrity, structure contract, attribution (kiali-blocking)

### Task 1: Hook rewrite (doc-validate.sh + hooks.json)

**Files:**
- Modify: `plugins/codebase-scribe/hooks/doc-validate.sh` (full rewrite)
- Modify: `plugins/codebase-scribe/hooks/hooks.json` (matcher line)
- Test: `plugins/codebase-scribe/hooks/test-doc-validate.sh` (create; committed test harness)

**Interfaces:**
- Produces: a hook script implementing spec §1's enforcement rules — two-tier contract (mature = TL;DR only, positional + fence-aware; stub = 5-section skeleton + TL;DR), docs_dir awareness, jq precedence, STATUS.md exclusion, advisory wording. Later tasks do not consume it directly, but Task 2's stub-row wording must match this script's stub test semantics exactly (anchored marker `*Stub — will be populated`, fences ignored).

- [ ] **Step 1: Write the failing test harness**

Create `plugins/codebase-scribe/hooks/test-doc-validate.sh` — a bash script that builds fixture files in a temp dir and pipes PostToolUse-shaped JSON (`{"tool_input":{"file_path":"<path>"}}`) into `doc-validate.sh`, asserting on output. Cases (via the two helpers `expect_warn <name> <path>` / `expect_silent <name> <path>`):

```bash
#!/bin/bash
# Test harness for doc-validate.sh. Run from this directory: bash test-doc-validate.sh
set -u
HOOK="$(cd "$(dirname "$0")" && pwd)/doc-validate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

invoke() { # $1=file_path
  printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash "$HOOK"
}
expect_warn() { # $1=name $2=path
  out="$(invoke "$2")"
  if printf '%s' "$out" | grep -q 'WARNING'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL(want-warn): $1"; fi
}
expect_silent() { # $1=name $2=path
  out="$(invoke "$2")"
  if [ -z "$out" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL(want-silent): $1 -> $out"; fi
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
( cd "$TMP/repo" && printf '{"tool_input":{"file_path":"docs/ai/t.md"}}' | env -u CLAUDE_PROJECT_DIR bash "$HOOK" | grep -q WARNING ) \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: custom-docs-dir-relative"; }
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
# warnings carry the systemMessage envelope
out="$(invoke "$D/no-heading.md")"
printf '%s' "$out" | grep -q '"systemMessage"' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: envelope"; }
# malformed JSON input -> silent on stdout AND stderr
out="$(printf 'not json' | bash "$HOOK" 2>"$TMP/mj.err")"
[ -z "$out" ] && [ ! -s "$TMP/mj.err" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: malformed-json"; }
# non-docs file silent
printf 'x' > "$TMP/repo/other.md"; expect_silent non-docs "$TMP/repo/other.md"

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run it against the current hook — expect failures**

Run: `bash plugins/codebase-scribe/hooks/test-doc-validate.sh`
Expected: FAIL count > 0 (current hook enforces 5 sections on everything, matches any `^>` blockquote, hardcodes `*/docs/agents/*.md`).

- [ ] **Step 3: Rewrite doc-validate.sh per spec §1**

Requirements (spec §1 "Hook fixes" + "Contract" + "Fence-awareness algorithm" — normative there):
1. Resolve `.scribe.yml` from `$CLAUDE_PROJECT_DIR` when that variable is set AND a `.scribe.yml` exists there; otherwise fall back to the current working directory. Extract docs_dir: an indented `docs_dir:` line inside the `output:` block only; strip quotes/trailing comments; default `docs/agents` on any failure. Leading-`/` value = exact path prefix.
2. Path match accepts absolute AND repo-relative `file_path`: for a non-`/`-leading docs_dir match against `*"$docs_dir"/*.md` and `"$docs_dir"/*.md`; for a leading-`/` docs_dir use it as an exact path prefix (`"$docs_dir"/*.md` only). Keep the `*/STATUS.md` exclusion.
3. jq precedence: use jq if present; else grep/sed extraction of `file_path`; if extraction yields nothing, exit 0 silently. Nothing on stderr on any path (`2>/dev/null` on probes).
4. Fence-aware scanning: one awk pass over the file toggling a flag on `` ^``` `` or `^~~~`; heading detection, TL;DR anchor, and stub-marker detection all count only lines with the flag off.
5. Stub test: any unfenced line beginning with `*Stub — will be populated` → stub tier → require the five `##` headings (`Key Entry Points`, `Patterns & Conventions`, `Gotchas`, `Dependencies & Context`, `Links`) AND the TL;DR. Otherwise mature tier → require only the TL;DR.
6. TL;DR check: after the closing `---` of frontmatter, the first non-blank line after the first unfenced `# ` line must start with `>`; a file with no unfenced `# ` heading warns.
7. Advisory wording, KEEPING the JSON envelope the host consumes: `{"systemMessage": "WARNING: <path> is missing required elements:<list>."}` — only the "Fix before proceeding" clause is removed. Always `exit 0`.

- [ ] **Step 4: Run the harness — expect PASS=all, FAIL=0**

Run: `bash plugins/codebase-scribe/hooks/test-doc-validate.sh`
Expected: `FAIL=0`, exit code 0. Then exercise the no-jq branch deterministically — build a PATH that **genuinely lacks jq** (never a failing jq stub: an executable stub makes `command -v jq` succeed, sends a correct hook down the jq branch to an empty extraction, and fails the suite on correct work):

```bash
SHIM="$(mktemp -d)"
for b in bash sh grep sed awk cat printf mktemp env rm mkdir dirname chmod ln head tail; do
  q="$(command -v "$b" 2>/dev/null)" && ln -s "$q" "$SHIM/$b"
done
if PATH="$SHIM" bash plugins/codebase-scribe/hooks/test-doc-validate.sh 2>"$SHIM/err.log" && test ! -s "$SHIM/err.log"; then
  echo NOJQ-OK
else
  echo "NOJQ-FAIL (suite rc or stderr present):"; cat "$SHIM/err.log"
fi
rm -rf "$SHIM"
```
Expected: `NOJQ-OK` (suite passes on the grep/sed path with zero stderr — spec §1’s "no stderr without jq"). If jq is not installed on this machine at all, the plain Step-4 run already exercised the no-jq path — record `command -v jq`’s output in the task notes either way.

- [ ] **Step 5: Update hooks.json matcher**

In `hooks/hooks.json` change `"matcher": "Write|Edit"` → `"matcher": "Write|Edit|MultiEdit"`. (Spec §1: harmless future-proofing; no acceptance depends on MultiEdit existing.)

- [ ] **Step 6: Commit**

```bash
git add plugins/codebase-scribe/hooks/
git commit -m "scribe: two-tier fence-aware hook with docs_dir support (spec §1)"
```

### Task 2: Two-tier contract in draft, maintain, and command Step 5

**Files:**
- Modify: `plugins/codebase-scribe/skills/scribe-draft/SKILL.md` — §3 structure rule (~line 158), Content standards 5-section rule (~line 199), §12 checklist (~line 372), Rework step 8 (~line 64)
- Modify: `plugins/codebase-scribe/skills/scribe-maintain/SKILL.md` — §7 structural validation (~line 143)
- Modify: `plugins/codebase-scribe/commands/codebase-scribe.md` — Step 5 `stub` row (~line 127)

**Interfaces:**
- Produces: the stub test wording used verbatim everywhere: "the body is empty or contains a line beginning with `*Stub — will be populated` outside fenced code blocks". Task 1's hook and Task 4's Step 5 table rely on identical semantics.

- [ ] **Step 1: Rewrite draft's four sites per spec §1 enforcement table**

1. §3's "**Every topic file MUST follow this exact structure** — no exceptions, no alternative layouts" block: replace with the positive redraft instruction (spec §1 Draft row, verbatim): the 5-section skeleton applies to stub drafts only; for a non-stub topic, draft preserves the existing top-level heading set and rewrites section bodies in place — adding a TL;DR and a `## Links` section only if absent — and (per the amended Safety Rule 2, Task 6) preserves `human_sections`-listed sections' existing prose verbatim while extending them.
2. Content standards "**Every topic MUST have all 5 sections**" sentence: scope to "content the draft generates for a *stub*".
3. §12 checklist first item ("File has exactly these 5 `##` headings…"): replace with the two-tier check (stub → 5 headings + TL;DR; mature → TL;DR, domain headings legitimate).
4. Rework step 8 ("…: 5 headings, TL;DR, scores, claims"): replace "5 headings" with "the two-tier structure check (per §12)".

- [ ] **Step 2: Rewrite maintain §7's heading check**

Replace "Verify each topic file has these 5 `##` headings…" with the two-tier contract: flag a missing TL;DR on any topic; on stubs additionally flag missing skeleton sections; add the advisory note for a missing `## Links` section on mature topics (spec §1: the Links advisory lives in maintain only).

- [ ] **Step 3: Rewrite command Step 5's stub row**

Replace `Body empty/<50 words, or placeholder text, or has migration_source` with: "body is empty or contains a line beginning with the stub placeholder marker (`*Stub — will be populated`) outside fenced code blocks, or has `migration_source`".

- [ ] **Step 4: Verify by grep**

```bash
cd plugins/codebase-scribe
! grep -rn "exactly these 5" commands skills --include="SKILL.md" --include="*.md" | grep -v eval
! grep -rn "50 words" commands/codebase-scribe.md
grep -n "will be populated" commands/codebase-scribe.md   # stub row present
```
Expected: first two greps empty; third shows the new row.

- [ ] **Step 5: Commit**

```bash
git add plugins/codebase-scribe/commands plugins/codebase-scribe/skills
git commit -m "scribe: two-tier structure contract across draft, maintain, Step 5 (spec §1)"
```

### Task 3: Default-branch ladder, Error Handling updates, branch-state threading

**Files:**
- Modify: `plugins/codebase-scribe/commands/codebase-scribe.md` — Step 0 (~line 29), Error Handling list (~lines 13–19)
- Modify: `plugins/codebase-scribe/skills/scribe-draft/SKILL.md` — Inputs (~lines 18–25), Rework Brief Contents (~lines 34–39)
- Modify: `plugins/codebase-scribe/skills/scribe-maintain/SKILL.md` — Inputs (~lines 20–24)
- Modify: `plugins/codebase-scribe/README.md` — config block (gains `default_branch`)

**Interfaces:**
- Produces: brief fields `default_branch`, `branching_strategy`, `current_branch` (plus `docs_dir` and repaired `watch_paths`, added in Tasks 5/13) documented in all three brief blocks. Tasks 4, 5, 7 rely on skills reading branch state from the brief, never re-detecting.

- [ ] **Step 1: Write the six-rung ladder into Step 0**

Transcribe spec §2 "Default-branch detection" rungs 1–6 verbatim (including rung 4's `main-only` refusal wording, rung 5's local `refs/heads/main`/`refs/heads/master` probe, rung 6's git-unavailable refusal). Add the detached-HEAD strategy split from §2 Threading (main-only refuses; branch-local proceeds with HEAD SHA; branch-commit refuses). Rename nothing here (the Step 0 heading rename is Task 25 with the autonomy removal — but if editing the heading region, do not reintroduce deleted text).

- [ ] **Step 2: Update the Error Handling list**

Per spec §2 "Error Handling updates": preamble gains "…except where an entry below explicitly refuses the run"; #5 rewritten per the strategy split; #6 rewritten to "No remote OR unresolvable default branch" with the `main-only` refusal documented; #4 noted as edited (git-unavailable rung; shallow-clone interaction added in Task 4); add `default_branch` (default: auto-detect) to the defaults list AND to the README config block (spec §2 rung 1 requires both); note `questions` arrives later (Task 24) — only add keys whose behavior this wave ships.

- [ ] **Step 3: Thread branch state into the three brief blocks**

Add to draft's Inputs, draft's Rework Brief Contents, and maintain's Inputs: `default_branch`, `branching_strategy`, `current_branch` — with the sentence "use the passed values; never re-detect" (spec §2 Threading).

- [ ] **Step 4: Verify**

```bash
grep -n "refs/remotes/origin/HEAD" plugins/codebase-scribe/commands/codebase-scribe.md
grep -n "default_branch" plugins/codebase-scribe/skills/scribe-draft/SKILL.md plugins/codebase-scribe/skills/scribe-maintain/SKILL.md
grep -n "No remote OR unresolvable" plugins/codebase-scribe/commands/codebase-scribe.md
grep -n "default_branch" plugins/codebase-scribe/README.md
```
Expected: all three match.

- [ ] **Step 5: Commit**

```bash
git add plugins/codebase-scribe
git commit -m "scribe: fail-closed default-branch ladder + branch-state threading (spec §2)"
```

### Task 4: Scan-SHA validation, shallow gate, Step 5 row table, session guard

**Files:**
- Modify: `plugins/codebase-scribe/commands/codebase-scribe.md` — Step 3 (~line 109), Step 4 (~line 119), Step 5 table (~lines 123–135), Error Handling list (~lines 13–19; Step 3b)
- Modify: `plugins/codebase-scribe/skills/scribe-maintain/SKILL.md` — §1 (~line 40), §2 table intro, §3 (~line 61), §4 (~line 80), §5 (~line 104), §8 (~line 157), §9 parenthetical (~line 171)

**Interfaces:**
- Consumes: Task 3's detected `default_branch` (for nothing here — validation is branch-independent); Task 2's stub row.
- Produces: the Step 5 table exactly as spec §2's normative table (stub / drifted / undercooked / decision_drift / unverified / current rows); the validation rules (`^[0-9a-f]{7,40}$`, `git cat-file -e` + `git merge-base --is-ancestor`, null never a failure); the shallow gate list. Tasks 6, 8, 21 rely on the row wording.

- [ ] **Step 1: Write the validation block into Step 3**

Transcribe spec §2 "Scan-SHA validation": shallow gate first (`git rev-parse --is-shallow-repository`, fallback `test -f .git/shallow`; the full skip list — Step 5 diff, maintain §1/§2/§3-rename/§4/§5/§8/§9-escalation, Step 4 session check; one warning; drafted-this-run topics still stamp freshness truthfully); shape/resolution/reachability tests for non-null scans; on failure classify per the table and persist `freshness: 0` at Step 3 before any STATUS.md regeneration.

- [ ] **Step 2: Replace the Step 5 table rows**

Rewrite the criteria of five rows per spec §2's table verbatim: `drifted`, `undercooked`, `decision_drift` (delete its "otherwise current" conjunct), `unverified` (four conjuncts incl. both absent-key defaults), and `current` = "no other row matched". Two rows are NOT touched: the `stub` row (owned by Task 2 — leave exactly as Task 2 wrote it, marker string included) and the **`escalated` row, which stays in the table unchanged at priority 2** (the spec's table omits it only because escalation routing is maintain §9's concern; Step 8 row 3 and the "unless a higher-priority row matches" rule both depend on it surviving). Add the note that the header diff command is skipped for null-scan topics.

- [ ] **Step 3: Guard maintain's stored-SHA consumers + Step 4**

Per spec §2 "Other stored-SHA consumers": maintain §1 reports full churn without running its diff on an unresolvable/unreachable SHA (feeding §2's table); §4/§5/§8 skip diff-derived branches; command Step 4 discards a session whose `last_active_sha` fails the same test; add the `_meta` no-guard note. Rewrite maintain §9 step 1's parenthetical to name the `escalated` classification.

- [ ] **Step 3b: Add the new Error Handling entry**

Append to the command's Error Handling list (that region of `commands/codebase-scribe.md` is part of this task's Files): "**Scan validation** — a non-null `scan` failing the shape/resolution/reachability tests classifies its topic `drifted` with `freshness: 0` persisted; in a shallow clone (see #4) scan validation and every diff-derived branch are skipped with a single warning and topics classify from body and frontmatter alone."

- [ ] **Step 4: Verify**

```bash
C=plugins/codebase-scribe/commands/codebase-scribe.md
grep -n "is-shallow-repository" $C && grep -n "0-9a-f\]{7,40}" $C && grep -n "no other row matched" $C
grep -n "merge-base --is-ancestor" $C
grep -nE '^\| .escalated. \|' $C   # the escalated ROW itself (line ~128) — an unanchored grep would be satisfied by Step 8 row 3’s prose
! grep -n "triggers the .undercooked. classification" plugins/codebase-scribe/skills/scribe-maintain/SKILL.md
! grep -n "otherwise current" $C
```
Expected: matches present; the two negated greps empty (the maintain one proves §9's parenthetical was retargeted).

- [ ] **Step 5: Commit**

```bash
git add plugins/codebase-scribe
git commit -m "scribe: scan-SHA validation, shallow gate, normative Step 5 rows (spec §2)"
```

### Task 5: Watch-path repair with persistence; delete draft §9

**Files:**
- Modify: `plugins/codebase-scribe/commands/codebase-scribe.md` — Step 3 (repair block)
- Modify: `plugins/codebase-scribe/skills/scribe-draft/SKILL.md` — delete §9 "Update Watch Paths" (~lines 310–313); §10's watch_paths mention (~line 317)

**Interfaces:**
- Consumes: Task 3's brief threading (adds `watch_paths` to the threaded fields).
- Produces: repaired directory-granularity `watch_paths` persisted in frontmatter at Step 3 and passed in the brief; draft §10 restamps from the brief value.

- [ ] **Step 1: Write the repair block into Step 3**

Transcribe spec §2 "watch_paths: directories forever": trailing-slash normalization; iterative parent-replacement until existing directory or single segment; dedupe; single-segment entries preserved (files and top-level dirs alike); preserved-but-dangling single segments reported in the Step 13 summary; write-back to frontmatter at Step 3 **before snapshots**; the two accepted-consequence notes (file-scope widening; purely mechanical).

- [ ] **Step 2: Delete draft §9; wire §10 to the brief**

Remove the `### 9. Update Watch Paths` heading and body entirely (numbering skips 8→10; do NOT renumber §10–§13). In §10's frontmatter list, change `watch_paths` to "watch_paths (the repaired value from the brief — never narrowed by draft)". Add `watch_paths` to the threaded brief fields in all three brief blocks from Task 3.

- [ ] **Step 3: Verify**

```bash
! grep -n "Update Watch Paths" plugins/codebase-scribe/skills/scribe-draft/SKILL.md
grep -n "### 10. Write Topic File" plugins/codebase-scribe/skills/scribe-draft/SKILL.md && ! grep -nE "^### 9\." plugins/codebase-scribe/skills/scribe-draft/SKILL.md
grep -n "single segment" plugins/codebase-scribe/commands/codebase-scribe.md
```
Expected: §9 gone, §10 still numbered 10, repair present.

- [ ] **Step 4: Commit**

```bash
git add plugins/codebase-scribe
git commit -m "scribe: iterative watch-path repair with frontmatter persistence; drop draft §9 (spec §2)"
```

### Task 6: Frontmatter preservation + human_sections (all sites)

**Files:**
- Modify: `plugins/codebase-scribe/skills/scribe-draft/SKILL.md` — Safety Rule 2 (~line 13), HARD RULE 4 (~line 94), §6 (~line 255), §7 (~line 293), §8 Human Input (~line 307), §10 write list (~line 317), §12 both checklist items (~lines 373, 377), Wrap-Up Pass (~lines 387–389)
- Modify: `plugins/codebase-scribe/skills/scribe-maintain/SKILL.md` — §8 Human Input (~line 159)
- Modify: `plugins/codebase-scribe/commands/codebase-scribe.md` — Step 3 items 1–2 (extraction list ~line 111; prune ~line 113)
- Modify: `plugins/codebase-scribe/skills/scribe-discover/SKILL.md` — add the overwrite-refusal rule

**Interfaces:**
- Produces: committed frontmatter keys `human_sections` (set of top-level slugs) and the preservation rule "any key not explicitly named by a writer is carried through unchanged"; the universal formula `human_input = (slugs in human_sections whose headings exist / total fence-aware ## sections) × 100`, 0 at zero sections. HARD RULE 4's dual duty. Tasks 8, 20, 21 rely on these exact semantics.

- [ ] **Step 1: Apply the spec's cross-cutting rules 1–3**

Transcribe from the spec's "Frontmatter key preservation and human attribution" section:
1. Carry-through rule + draft §10 amendment ("…and preserved verbatim: `decisions`, `question_passes`, `human_sections`, `review_notes`, and any other keys present").
2. `human_sections` definition (set semantics; written when HARD RULE 4 fires; pruned only on heading disappearance; heading↔slug mapping via draft §4's slug algorithm on fence-aware `##` headings — that set is also the denominator).
3. Discover overwrite-refusal + collision handling (creates remaining topics, returns colliding names; orchestrator drops them from the batch — including focus-mode — never re-attempts, surfaces in Step 13 with a rename suggestion). Put the refusal in discover's HARD RULES and the handling in command Steps 2d/6d.

- [ ] **Step 2: Rewrite the computation and trigger sites**

- Draft §8 Human Input: delete the zero-rule sentence; the formula is universal (from `human_sections`).
- Maintain §8 Human Input: same formula (no zero-rule).
- HARD RULE 4: dual duty — add the slug to `human_sections` AND remove it from `inferred_sections`; replace the stale rationale sentences ("This drives the `human_input` score…").
- §6 and §7 incorporation sentences: point at HARD RULE 4 instead of restating half of it, AND carry spec §4’s target rule verbatim: append to `Dependencies & Context` or `Gotchas`; if neither exists, to the last `##` section; if the topic has no `##` section, create `## Dependencies & Context` and append there. (This rule is owned HERE — Task 21’s question-pass pipeline references it.)
- Both §12 checklist items: rewrite to the `human_sections` basis.
- Wrap-Up Pass: add the slug to `human_sections`, remove from `inferred_sections`, recompute `human_input`, rewrite touched topics' frontmatter (it runs after §8/§10).
- Safety Rule 2: append "sections listed in `human_sections` may be extended, but their existing prose must be preserved verbatim."

- [ ] **Step 3: Extend Step 3 (extraction, prune, ### bug)**

Extraction list adds `decisions`, `question_passes` (absent ⇒ 0), `human_sections`. Prune item 2: also prune `human_sections` orphans; extend the heading comparison to check `###` entries against `###` headings (pre-existing bug: `###` entries were compared against `##` headings and always pruned).

- [ ] **Step 4: Verify**

```bash
D=plugins/codebase-scribe/skills/scribe-draft/SKILL.md
grep -n "human_sections" $D plugins/codebase-scribe/skills/scribe-maintain/SKILL.md plugins/codebase-scribe/commands/codebase-scribe.md | wc -l   # expect >= 8
! grep -n "the score is 0" $D
! grep -n "This drives the .human_input. score" $D
grep -n "preserved verbatim" $D | head -2
```

- [ ] **Step 5: Commit**

```bash
git add plugins/codebase-scribe
git commit -m "scribe: human_sections positive attribution wired into every site (spec cross-cutting)"
```

### Task 7: Branch gate at every stamping site; self-certification freeze

**Files:**
- Modify: `plugins/codebase-scribe/commands/codebase-scribe.md` — Step 0 refusal wording, 9f items 3–4 (~lines 370–371)
- Modify: `plugins/codebase-scribe/skills/scribe-draft/SKILL.md` — §8 freshness, §10 scan, Rework step 6 (~line 60), Review Gate item 6 (~line 639)
- Modify: `plugins/codebase-scribe/skills/scribe-maintain/SKILL.md` — §8 scan-advance sentence (~line 163)

**Interfaces:**
- Consumes: Task 3's brief branch state.
- Produces: the stamping predicate "drafted or reworked in this run" used by 9f, and the rule that maintain never advances `scan`. Task 21's question-pass exclusion extends these same sites.

- [ ] **Step 1: Apply the branch-gate refusals (main-only scoped)**

At 9f, draft §8, draft §10, draft Rework step 6, maintain §8, and draft's Review Gate item 6 (wave-1 interim guard — the item is deleted in wave 3): "under `branching_strategy: main-only`, when `current_branch` != `default_branch` (from the brief), do not update `freshness` or `scan`." Step 0's exit gets the explicit refusal wording per spec §2.

- [ ] **Step 2: Freeze self-certification**

9f items 3–4 become conditional: stamp `freshness: 100` and advance `scan` **only for topics whose content was drafted or reworked in this run**; after a maintain-only pass preserve maintain §8's computed freshness and do not advance `scan`. Delete maintain §8's "Update `scan` SHA to current HEAD if changes were made." Also apply the shallow-gate carve-out from Task 4 (drafted-this-run topics stamp truthfully).

- [ ] **Step 3: Verify**

```bash
! grep -n "Update .scan. SHA to current HEAD if changes were made" plugins/codebase-scribe/skills/scribe-maintain/SKILL.md
grep -n "drafted or reworked" plugins/codebase-scribe/commands/codebase-scribe.md
grep -n "default_branch" plugins/codebase-scribe/skills/scribe-draft/SKILL.md | head -3
```

- [ ] **Step 4: Commit**

```bash
git add plugins/codebase-scribe
git commit -m "scribe: branch gate at all stamping sites; maintain never advances scan (spec §2)"
```

### Task 8: Wave-1 kiali bundle — gitignore seeding, migration, id reservation

**Files:**
- Modify: `plugins/codebase-scribe/commands/codebase-scribe.md` — new Phase 0 Step 1 sub-block (seeding + migration), Step 13 reporting lines
- Modify: `plugins/codebase-scribe/skills/scribe-draft/SKILL.md` — §11 id assignment (~lines 324–326)
- Modify: `plugins/codebase-scribe/skills/scribe-maintain/SKILL.md` — §6 id assignment (~lines 124, 128)

**Interfaces:**
- Consumes: Task 6's `decisions`/`human_sections` keys and extraction.
- Produces: the `decisions:` schema written by migration (id, type, claim, context, recorded, source, status; optional resolved_at documented but written by Task 23); the id-reservation rule "sequential assignment skips ids named in frontmatter `decisions:` (active and retired) and `_retired_ids`" in BOTH draft §11 and maintain §6.

- [ ] **Step 1: Add gitignore seeding to Phase 0 Step 1**

Per spec §4 M9: idempotent append of `.scribe/` and `<docs_dir>/.claims.yml` (skip if present; create `.gitignore` if absent; skip the claims entry when the resolved docs_dir is already under an ignored path). Report any `.gitignore` modification in Step 13.

- [ ] **Step 2: Add the claims migration after seeding**

Transcribe spec §4's migration bullet: split trigger (reconstruction fires when `<docs_dir>/.claims.yml` exists and holds `origin: user` claims, tracked or not; the untrack step alone is gated on `git ls-files --error-unmatch` succeeding AND an AskUserQuestion approval); per-decision idempotent (skip a decision whose `{type, topic, first-50-chars}` already exists); field mapping (id←claim.id, type←claim.type, claim←claim.claim, context←provenance.context, recorded←provenance.recorded, source←claim.source, status: active); `human_sections` credit only when exactly one `##` section's body contains the claim text; staged untrack + gitignore change reported in Step 13 with a commit instruction.

- [ ] **Step 3: Add id reservation at both assignment sites**

Draft §11 and maintain §6 each gain: "when assigning sequential ids, skip every id named in frontmatter `decisions:` (active and retired) in addition to `_retired_ids`."

- [ ] **Step 4: Verify**

```bash
C=plugins/codebase-scribe/commands/codebase-scribe.md
grep -n "ls-files --error-unmatch" $C && grep -n "gitignore" $C | head -3
grep -n "decisions" plugins/codebase-scribe/skills/scribe-draft/SKILL.md | grep -in "skip" 
grep -n "decisions" plugins/codebase-scribe/skills/scribe-maintain/SKILL.md | grep -in "skip"
```

- [ ] **Step 4b: Record the kiali trackedness evidence**

Per spec §4, the trackedness of kiali's `.claims.yml` is field data re-verified at implementation time: check it (e.g. GitHub API `git/trees` for the kiali default branch, or a shallow clone) and record the outcome in the wave-1 PR description. The split trigger makes the migration correct either way — this step is evidence hygiene, not a gate.

- [ ] **Step 5: Commit, then open the wave-1 PR**

```bash
git add plugins/codebase-scribe
git commit -m "scribe: wave-1 kiali bundle — seeding, provenance migration, id reservation (spec §4)"
```
Open a PR to fork main titled "scribe wave 1: drift integrity, structure contract, attribution". Wave-1 acceptance sweep before opening it — run every grep from Tasks 1–8 once more from a clean `git stash`-free tree.

---

## Wave 2 — discover/hub untangle, docs_dir threading

### Task 9: Discover reduced to stubs + STATUS.md

**Files:**
- Modify: `plugins/codebase-scribe/skills/scribe-discover/SKILL.md` — delete the hub paragraph (~line 75), parameterize paths

**Interfaces:**
- Consumes: brief `docs_dir` (Task 12 threads it; write discover against it now — "the docs_dir provided by the orchestrator (default `docs/agents`)").
- Produces: discover writes only `<docs_dir>/<name>.md` stubs and `<docs_dir>/STATUS.md`; never touches AGENTS.md; refuses overwrites (Task 6).

- [ ] **Step 1: Delete the "If no AGENTS.md exists, create a hub…" paragraph entirely.** HARD RULE 2 stays as the sole AGENTS.md mention ("Do NOT touch AGENTS.md").
- [ ] **Step 2: Replace hardcoded `docs/agents/` at lines ~9, ~28, ~73 with "the docs_dir provided by the orchestrator (default `docs/agents`)".**
- [ ] **Step 3: Verify:** `! grep -n "create a hub" plugins/codebase-scribe/skills/scribe-discover/SKILL.md` and `! grep -n "ARCHITECTURE.md" plugins/codebase-scribe/skills/scribe-discover/SKILL.md`.
- [ ] **Step 4: Commit** — `git commit -am "scribe: discover creates stubs and STATUS.md only (spec §5)"`

### Task 10: Step 12 — 12f hub template, orphan-mode collapse, heading match, P7

**Files:**
- Modify: `plugins/codebase-scribe/commands/codebase-scribe.md` — Step 1 orphan block (~lines 41–49) deleted; Step 12 (12a–12e edits; new `#### 12f: Hub template`)

**Interfaces:**
- Produces: 12f as the single hub template (the markdown block in spec §5, verbatim, incl. the conditional ARCHITECTURE.md pointer rule and 12d's later-add duty in full-management mode); the uniform Documentation-heading rule (exact `## Documentation` preferred → first `##` containing "Documentation" case-insensitive → create); marker placement scoped to 12e option 2; the migration re-point rule; identity-read allowance at 12b opt 1 / 12c / 12e opt 1; P7 exact-match footer removal owned by 12d full-management.

- [ ] **Step 1: Delete Step 1's "Orphan mode hub generation" subsection AND rewrite Step 1's routing-table cell** (currently "**Orphan mode** → generate AGENTS.md hub from existing topic frontmatter (see below), then Step 3") to "**Orphan mode** → Step 3 (AGENTS.md is created at Step 12 via 12c)".
- [ ] **Step 2: Insert `#### 12f: Hub template`** with the spec §5 template block verbatim, its population rules ("see build files" for unknown cells), the conditional ARCHITECTURE.md pointer, and the identity-read allowance sentence covering 12b option 1, 12c, and 12e option 1 (which may also read the backup it creates).
- [ ] **Step 3: Point 12b option 1, 12c "Does not exist", and 12e option 1 at 12f** (replacing all three "discover skill's hub template" references).
- [ ] **Step 4: Apply the heading-match rule** to 12d (both variants + create-if-missing) and 12e option 2; the marker-above-heading sentence to 12e option 2 only. Add 12d's full-management duties: append the ARCHITECTURE pointer if absent and the file now exists; remove exact-match legacy footers only when no stubs remain — **retrieve the two footer strings from the kiali AGENTS.md hub first** (spec §5 gives fragments, not literals: "…these stubs" / "…the stubs", with/without backticks), quote the observed strings literally in 12d, record them in the wave-2 PR description; if the hub cannot be retrieved, record that and mark the P7 acceptance criterion conditionally unmet (spec §5 makes it conditional on exactly this verification).
- [ ] **Step 5: Add the migration re-point rule** to 12e option 1: on creating a backup, rewrite every topic frontmatter whose unconsumed `migration_source` names the renamed file to the backup filename. In draft's migration flag message (~line 156), replace the literal `AGENTS.md.bak` with "the file named by `migration_source`".
- [ ] **Step 6: Verify:** `! grep -n "discover skill's hub template" plugins/codebase-scribe/commands/codebase-scribe.md`; `grep -n "12f" plugins/codebase-scribe/commands/codebase-scribe.md | head -5`; `! grep -n "Orphan mode hub generation" plugins/codebase-scribe/commands/codebase-scribe.md`; `! grep -n "generate AGENTS.md hub from existing topic frontmatter" plugins/codebase-scribe/commands/codebase-scribe.md`.
- [ ] **Step 7: Commit** — `git commit -am "scribe: single 12f hub template, orphan collapse, heading match, P7 (spec §5)"`

### Task 11: Seed-run flow + snapshot-deletion site

**Files:**
- Modify: `plugins/codebase-scribe/commands/codebase-scribe.md` — Step 2d (~line 107), Step 1 (snapshot deletion), Step 13

**Interfaces:**
- Produces: both entry paths into Step 2 continue to Steps 10–13; exactly one "run again" message (Step 13's); `.scribe/snapshots/` deleted at Phase 0 Step 1 on every run path (written at Step 8 from wave 3).

- [ ] **Step 1:** Delete Step 2d's "Stubs created. Run `/codebase-scribe` again…" message; add "then continue to Steps 10–13" to 2d, stated for both the first-run route and Step 8 row 7's uncovered-modules route.
- [ ] **Step 2:** Add to Phase 0 Step 1: "delete `.scribe/snapshots/` if present (rewritten by Step 8 each run)."
- [ ] **Step 3: Verify:** `grep -c "codebase-scribe. again" plugins/codebase-scribe/commands/codebase-scribe.md` returns **3** (baseline 4 — Step 13's per-mode block keeps its three lines; Step 2d's copy is the one deleted).
- [ ] **Step 4: Commit** — `git commit -am "scribe: seed flow continues to hub creation; snapshot deletion at Step 1 (spec §5, §3)"`

### Task 12: docs_dir threading everywhere

**Files:**
- Modify: `plugins/codebase-scribe/commands/codebase-scribe.md` — preamble (~line 9), Step 3, Step 10, 9f item 6; Phase 0 resolution + brief threading sentence
- Modify: `plugins/codebase-scribe/skills/scribe-draft/SKILL.md` — claims path (~line 367), STATUS.md (~line 393), README links (~line 485), ARCHITECTURE template links (~lines 532–543), CLAUDE/GEMINI bodies (~lines 557, 573)
- Modify: `plugins/codebase-scribe/skills/scribe-maintain/SKILL.md` — claims (~line 116), STATUS.md (~line 185), standard-files checks (~lines 206–214)

**Interfaces:**
- Produces: every behavioral `docs/agents` reference reads "the configured docs_dir (default `docs/agents`)"; Phase 0 resolves once (with the `branch-local` override winning and Step 3's mismatch warning suppressed under it) and passes `docs_dir` in every skill brief. Task 15 adds it to the review (9c) brief.

- [ ] **Step 1:** Sweep and replace per the file list. Rule of thumb: instruction text → the configured-docs_dir phrase; generated *content* (README/ARCHITECTURE/CLAUDE/GEMINI link targets) → "link to `<docs_dir>/<name>.md>` using the resolved value".
- [ ] **Step 2:** Add the Phase 0 resolution + brief threading + branch-local precedence sentences per spec §5. Also add the orphan-mode fallback to draft's Standard Files block (spec §5 “Orphan-mode draft input”): where README/ARCHITECTURE generation pulls project identity “from AGENTS.md or existing README”, note that in an orphan-mode run AGENTS.md does not yet exist (Step 12 creates it later), so the repo README is the identity source.
- [ ] **Step 3: Verify:** `grep -rn "docs/agents" plugins/codebase-scribe/commands plugins/codebase-scribe/skills --include="*.md" | grep -v eval | grep -v "default"` — every remaining hit must be a default-value mention — list and justify each. One justified hit is expected: `skills/scribe-review/SKILL.md` (~line 57) keeps its hardcoded `docs/agents/` until wave 3 (Task 14’s merge replaces it with the brief-supplied `docs_dir`).
- [ ] **Step 4: Commit; open the wave-2 PR** — `git commit -am "scribe: docs_dir threaded end-to-end with branch-local precedence (spec §5)"`

---

## Wave 3 — review agent (gated by the Cursor pre-check)

### Task 13: Cursor pre-check (manual, gating)

**Files:** none (verification task; results recorded in the PR description)

- [ ] **Step 1:** In Claude Code: dispatch the existing `code-reviewer` plugin's `adversarial-reviewer` agent by bare name via the Agent tool with a trivial prompt; record that it resolves. Then create a throwaway `agents/scribe-review.md` stub (frontmatter only, prompt "reply OK") on a scratch branch, **reload the plugin so the host discovers it** (e.g. `/reload-plugins`, or a local marketplace re-install if the session loads the installed copy rather than the working tree — record which); verify the identifier that resolves (bare `scribe-review` vs namespaced). Delete the scratch branch.
- [ ] **Step 2:** In Cursor: repeat both dispatches. If either fails, STOP the wave and surface the decision (spec §3 pre-check).
- [ ] **Step 3:** Record outcomes (identifier form; Cursor result) in the wave-3 PR description. Task 15's dispatch sentence uses the verified identifier.

### Task 14: Create agents/scribe-review.md (merged protocol)

**Files:**
- Create: `plugins/codebase-scribe/agents/scribe-review.md`
- Delete: `plugins/codebase-scribe/skills/prompts/review-adversarial.md` (directory `skills/prompts/` removed)

**Interfaces:**
- Produces: the agent — frontmatter `name: scribe-review`, `description`, `color: blue`, `tools: Read, Bash, Grep, Glob`, NO `model` key. System prompt = merged `skills/scribe-review/SKILL.md` + `skills/prompts/review-adversarial.md`, preserving both divergence directions (SKILL.md's Scoped Re-Review + "if in doubt → REWORK_NEEDED"; the prompt's "Common LLM Documentation Errors" + changelog-language → CONTRADICTION rule). Inputs section rewritten: `source_files` is a prioritized list of PATHS; brief includes `docs_dir`. Recommendation lines per Task 16.

- [ ] **Step 1:** Write the agent file: concatenate-and-merge the two sources, deduplicating the shared tables (classification, report format) — keep the stricter/superset variant of each divergent passage; rewrite the Inputs section (paths-only; add `docs_dir` — the cross-topic check reads "topic files in `<docs_dir>`").
- [ ] **Step 2:** Delete `skills/prompts/`.
- [ ] **Step 3: Verify:** `test -f plugins/codebase-scribe/agents/scribe-review.md && ! test -d plugins/codebase-scribe/skills/prompts`; grep the agent for both merge markers: `grep -n "Scoped Re-Review" plugins/codebase-scribe/agents/scribe-review.md && grep -n "Common LLM Documentation Errors" plugins/codebase-scribe/agents/scribe-review.md`.
- [ ] **Step 4: Commit** — `git add plugins/codebase-scribe/agents plugins/codebase-scribe/skills && git commit -m "scribe: scribe-review agent with merged adversarial protocol (spec §3)"` (`-a` cannot stage the new untracked agent file). Note: the command still references the deleted prompts file until Task 15 — acceptable inside the single wave-3 PR.

### Task 15: Dispatch cutover in the command (9c, 9d, Step 8 rule, Step 9 preamble)

**Files:**
- Modify: `plugins/codebase-scribe/commands/codebase-scribe.md` — 9c (~lines 263–280), 9d item 3 (~line 301), Step 8 rule (~line 195), Step 9 preamble (~line 220)

**Interfaces:**
- Consumes: Task 13's verified identifier; Task 14's agent.
- Produces: sites 1–2 carry the spec §3 quoted dispatch sentence (with the verified identifier substituted); 9c's `source_files` block is paths-only with `docs_dir` added to the brief; Step 8's sub-skill rule has the scope clause + retained rationale sentence; Step 9's preamble second sentence replaced; the 9d→9e escalation mapping is NOT touched here — spec §3 explicitly assigns the 9e widening to §8 alone (renumbering-dependent); Task 25 owns it entirely.

- [ ] **Step 1:** Replace 9c's Skill-tool instruction and its trailing sentence with the quoted dispatch sentence (spec §3), the paths-only `source_files` block, and `docs_dir` in the brief. Same dispatch sentence at 9d item 3.
- [ ] **Step 2:** Rewrite Step 8's rule with the spec's replacement text (scope clause + rationale sentence + review-dispatch exception). Replace Step 9's preamble second sentence with "The skills invoke Step 9 as a whole via their Review Gate pointers."
- [ ] **Step 3: Verify:** `! grep -n "NOT the .Agent. tool" plugins/codebase-scribe/commands/codebase-scribe.md`; `grep -c "Agent tool" plugins/codebase-scribe/commands/codebase-scribe.md` ≥ 2; `! grep -rn "review-adversarial" plugins/codebase-scribe/commands`.
- [ ] **Step 4: Commit** — `git commit -am "scribe: review dispatch via Agent tool at 9c/9d (spec §3)"`

### Task 16: Dispatching stub + P3 recommendation lines

**Files:**
- Modify: `plugins/codebase-scribe/skills/scribe-review/SKILL.md` — full replacement with the dispatching stub
- Modify: `plugins/codebase-scribe/agents/scribe-review.md` — Recommendation section

**Interfaces:**
- Produces: the stub (spec §3 wording — supersession note + the operative instruction: construct the 9c brief from provided inputs, dispatch the agent, return its report verbatim). Agent recommendation lines: "Run `/codebase-scribe` again — targeted correction of sections: <list>." / "… — full redraft recommended."; PASS line unchanged; guidance paragraph restated as targeted-correction vs full-redraft.

- [ ] **Step 1:** Replace `skills/scribe-review/SKILL.md` body (keep frontmatter name/description) with the dispatching stub text from spec §3.
- [ ] **Step 2:** In the agent, rewrite the Recommendation block per spec §3 P3.
- [ ] **Step 3: Verify:** `! grep -rn "codebase-scribe:scribe-maintain\|codebase-scribe:scribe-draft" plugins/codebase-scribe/agents plugins/codebase-scribe/skills/scribe-review/SKILL.md`.
- [ ] **Step 4: Commit** — `git commit -am "scribe: dispatching stub + corrected recommendation lines (spec §3)"`

### Task 17: M2 reduction + contributing.md clause

**Files:**
- Modify: `plugins/codebase-scribe/skills/scribe-draft/SKILL.md` — Review Gate section (~lines 628–641)
- Modify: `plugins/codebase-scribe/skills/scribe-maintain/SKILL.md` — §12 (~lines 221–233)
- Modify: `docs/contributing.md` — agent checklist line (~line 43)

**Interfaces:**
- Produces: both Review Gate sections as the spec §3 reduced pointer texts (draft keeps the rework-skip first line AND the leading precondition; maintain keeps its precondition and appends the summary-ordering clause). contributing.md checklist gains "` model` optional for plugins shipping to multiple hosts".

- [ ] **Step 1:** Replace both sections with the spec's quoted reduced texts verbatim.
- [ ] **Step 2:** Append the model-optional clause to the contributing.md checklist item.
- [ ] **Step 3: Verify:** `! grep -nE '\(Step 9[a-f]\)' plugins/codebase-scribe/skills/scribe-draft/SKILL.md plugins/codebase-scribe/skills/scribe-maintain/SKILL.md` (the reduced pointer texts name Step 9c/9d without parentheses, so this pattern is specific to the deleted numbered substep lists); `grep -n "Skip this section when in rework mode" plugins/codebase-scribe/skills/scribe-draft/SKILL.md`; `grep -n "optional for plugins" docs/contributing.md`.
- [ ] **Step 4: Commit** — `git commit -am "scribe: Review Gate pointers; model-optional clause in contributing.md (spec §3)"`

### Task 18: Snapshots to disk (Step 8 / 9a)

**Files:**
- Modify: `plugins/codebase-scribe/commands/codebase-scribe.md` — Step 8 pre-invocation snapshots (~lines 197–204), 9a (~lines 224–233)

**Interfaces:**
- Consumes: Task 11's Step-1 deletion site.
- Produces: Step 8 writes `.scribe/snapshots/<topic>.md` (full file incl. frontmatter), `<topic>.claims.yml`, `<topic>.headings.txt`; scope = draft batch / all topics for maintain; zero-byte sentinel for not-yet-existing topics; gitignore belt-and-braces check before writing. 9a: reads pre-skill `scan` from the snapshot's frontmatter; zero-byte → `new_draft`; absent-but-modified → `major_rewrite`; diffs via `git diff --no-index`.

- [ ] **Step 1:** Rewrite Step 8's snapshot block and 9a items per spec §3 "Snapshots to disk", verbatim on the sentinel semantics.
- [ ] **Step 2: Verify:** `grep -n "snapshots/" plugins/codebase-scribe/commands/codebase-scribe.md | head -5`; `grep -n "zero-byte" plugins/codebase-scribe/commands/codebase-scribe.md`.
- [ ] **Step 3: Commit** — `git commit -am "scribe: on-disk pre-invocation snapshots with sentinel semantics (spec §3)"`

### Task 19: In-wave eval-runner verification (question 3)

**Files:** scratch only (throwaway fixture; not committed)

- [ ] **Step 1:** Hand-author one throwaway fixture supplying a Step 9c brief (a small topic file + 3 claims + paths) and invoke the dispatching stub under the eval runner (or, if the runner is unavailable locally, via a direct Skill invocation shaped like the runner's). Confirm the agent's full report appears in the captured conversation.
- [ ] **Step 2:** If it does not: apply the derived-copy fallback (spec §3) — regenerate `skills/scribe-review/SKILL.md` as a protocol copy mechanically derived from the agent file with a generation header naming the source, and add the copy to Task 28's sync check list. Record the branch taken in the PR description.
- [ ] **Step 3:** Discard the fixture. Open the wave-3 PR with the pre-check + verification outcomes recorded.

---

## Wave 4 — knowledge persistence remainder

### Task 20: decisions lifecycle — write timing, re-linking, tombstones, resolved_at

**Files:**
- Modify: `plugins/codebase-scribe/skills/scribe-draft/SKILL.md` — §6/§7 provenance blocks (~lines 255–300), §11 (~lines 320–367), Decision Drift Resolution (~lines 96–114)
- Modify: `plugins/codebase-scribe/skills/scribe-maintain/SKILL.md` — §4 (~lines 78–99), §6 (~lines 110–137)

**Interfaces:**
- Consumes: Task 8's schema and reservation.
- Produces: `decisions:` entries written at §11 (never §6/§7 — they record the answer; the entry lands with its id after extraction); re-linking by `{type, topic, first-50-chars}` against active entries with both uniqueness guards (many-to-one → first in `.claims.yml` order binds; one-to-many → none, reported); unmatched-active-decisions report; tombstones (`status: retired`) written by all three Decision Drift Resolution outcomes; `resolved_at` written on resolution, consumed by §4 as "resolved_at when it is a descendant of scan (`git merge-base --is-ancestor`), else scan", ignored (fail toward re-detection) when unresolvable.

- [ ] **Step 1:** Apply the write-timing rule and the §11 entry-write; rewrite maintain §6's re-link block per spec §4; rewrite the three Decision Drift Resolution outcomes to write frontmatter first (update recorded / update context+recorded / set `status: retired`) and stamp `resolved_at`.
- [ ] **Step 2:** Rewrite maintain §4 to read frontmatter `decisions:` (active only) and diff from the ancestry-selected base.
- [ ] **Step 3: Verify:** `grep -n "resolved_at" plugins/codebase-scribe/skills/scribe-maintain/SKILL.md plugins/codebase-scribe/skills/scribe-draft/SKILL.md | wc -l` ≥ 3; `grep -n "status: retired" plugins/codebase-scribe/skills/scribe-draft/SKILL.md`.
- [ ] **Step 4: Commit** — `git commit -am "scribe: decisions lifecycle — timing, content re-link, tombstones, resolved_at (spec §4)"`

### Task 21: Question-pass contract

**Files:**
- Modify: `plugins/codebase-scribe/commands/codebase-scribe.md` — Step 8 `unverified` row (~line 192), 9f reset rule
- Modify: `plugins/codebase-scribe/skills/scribe-draft/SKILL.md` — new "Question-Pass Mode" section (mirroring Rework Mode's shape: flag, pipeline, NOT-done list)

**Interfaces:**
- Consumes: Tasks 4 (unverified row), 6 (incorporation + human_sections), 7 (stamping predicate), 20 (§11 write timing).
- Produces: `question_pass: true` brief flag; the pipeline and NOT-done list per spec §4 (increment on every pass incl. zero-question outcomes; HARD RULE 1 in force, HARD RULE 2 disapplied; no freshness/scan stamp — enforced in the draft §8/§10 conditionals from Task 7 by extending their condition to "and not a question pass"); the two-condition 9f reset (drafted-or-reworked AND NOT (passes==2 ∧ human_input==0)) with the draft-side fallback restricted to the two 9f-bypassing paths carrying condition (b), 9b-path reset evaluated after Step 9 returns.

- [ ] **Step 1:** Write the Question-Pass Mode section into draft (flag, pipeline incl. the incorporation-target rule reference and counter semantics, NOT-done list) per spec §4, verbatim on the counter and reset rules.
- [ ] **Step 2:** Respecify Step 8's `unverified` row to pass `question_pass: true`; write the 9f reset rule with both conditions; extend draft §8/§10's stamping conditionals with the question-pass exclusion.
- [ ] **Step 2b:** Write the draft-side reset fallback: on the two 9f-bypassing paths only (`review.enabled: false` — applied at finalization of a full redraft; the 9b-skip path — evaluated after Step 9 returns for the topic), draft resets `question_passes` to 0, carrying the same condition (b) (never reset when `question_passes == 2` with `human_input == 0`).
- [ ] **Step 3:** Note in draft §6 that a stub's first-draft question does not increment `question_passes` (M3 passes only; user-visible ask ceiling is three).
- [ ] **Step 4: Verify:** `grep -n "question_pass" plugins/codebase-scribe/commands/codebase-scribe.md plugins/codebase-scribe/skills/scribe-draft/SKILL.md | wc -l` ≥ 4.
- [ ] **Step 5: Commit; open the wave-4 PR** — `git commit -am "scribe: question-pass mode with settling semantics (spec §4)"`

---

## Wave 5 — strip, batching, content standards, autonomy removal

### Task 22: The #39 strip (isolated revertible commit)

**Files:**
- Modify: `plugins/codebase-scribe/skills/scribe-draft/SKILL.md` — Step A upstream-detection block (~lines 409–416), `docs/upstream.md` classification rules (~lines 434–437), Step A file enumeration entry (~line 418 incl. the "or `docs/`" parenthetical), Step B upstream question + prompt-order entry (~lines 441–453), Step C upstream template + rules (~lines 580–620), ARCHITECTURE upstream link rule (~line 545)
- Modify: `plugins/codebase-scribe/commands/codebase-scribe.md` — Step 13 `docs/upstream.md` mention (~line 465)

- [ ] **Step 1:** Delete all seven sites. NOTHING else in this commit.
- [ ] **Step 2: Verify:** `grep -rni "upstream" plugins/codebase-scribe/commands plugins/codebase-scribe/skills plugins/codebase-scribe/hooks plugins/codebase-scribe/README.md --include="*.md" --include="*.sh" | grep -v eval` → empty.
- [ ] **Step 3: Commit (isolated):**

```bash
git add plugins/codebase-scribe/skills/scribe-draft/SKILL.md plugins/codebase-scribe/commands/codebase-scribe.md
git diff --cached --stat                      # exactly the two files
# mechanical isolation check at HUNK granularity (a deleted template block contains
# blank/structural lines that don't literally say "upstream" — line-level checks false-positive):
git diff --cached -U0 | awk '
  /^@@/ { if (h != "" && !u) print "SUSPECT HUNK: " h; h=$0; u=0; next }
  /^[+-]/ && !/^(\+\+\+|---)/ { if (tolower($0) ~ /upstream/) u=1 }
  END { if (h != "" && !u) print "SUSPECT HUNK: " h }'
# expected: EMPTY — every changed hunk mentions upstream somewhere. Residual, stated:
# a stray non-upstream edit CONTIGUOUS with an upstream deletion shares its hunk and is
# invisible to this check — the full-diff eyeball below is the backstop for that case.
git diff --cached   # eyeball in full
git commit -m "scribe: strip Red Hat upstream.md contextification (revertible; a future revert re-adds upstream as a multiSelect option post-P2)"
```

### Task 23: P2 prompt batching

**Files:**
- Modify: `plugins/codebase-scribe/skills/scribe-draft/SKILL.md` — Step B (~lines 439–453)

- [ ] **Step 1:** Replace the sequential per-file prompts with one multiSelect AskUserQuestion listing each missing/thin file as an option, its classification ("thin, ~N lines" / "missing") in the description; a second call only if more files qualify than fit one question's options (verify the host limit at implementation and note it inline). Delete Step B's "one at a time, sequentially (do not batch)" clause. **Do NOT touch §7's identically-worded focus-mode HARD RULE.**
- [ ] **Step 2: Verify:** `! grep -n "do not batch" plugins/codebase-scribe/skills/scribe-draft/SKILL.md` (the deleted Step B clause was the ONLY occurrence of that string in the file) AND `grep -n "never batched" plugins/codebase-scribe/skills/scribe-draft/SKILL.md` present (§7’s focus-mode HARD RULE — differently worded, untouched; the spec’s "identically-worded" description is inaccurate on this point).
- [ ] **Step 3: Commit** — `git commit -am "scribe: batch Standard Files prompts into multiSelect (spec §6 P2)"`

### Task 24: Content standards + questions config

**Files:**
- Modify: `plugins/codebase-scribe/skills/scribe-draft/SKILL.md` — content standards (~lines 197–204), HARD RULE 2 + §11 claim counts, §6 zero-question rule
- Modify: `plugins/codebase-scribe/commands/codebase-scribe.md` — Error Handling defaults (`questions: true`)
- Modify: `plugins/codebase-scribe/skills/scribe-maintain/SKILL.md` — §6 re-extraction claim-count sentence
- Modify: `plugins/codebase-scribe/README.md` — config block

- [ ] **Step 1:** Add the citation rule (symbol-in-file, never bare line numbers) and the volatile-inventory rule to draft's content standards; change "15-20 claims" to "up to 15–20, proportional to content — do not pad small topics" (draft HARD RULE 2, draft §11, AND maintain §6’s re-extraction sentence — maintain’s SKILL.md is in this task’s Files); make §6's one-question rule conditional (zero questions allowed when only a conventional-choice fallback remains).
- [ ] **Step 2:** Add flat `questions: true` to the defaults list and README config block with the suppression list (suppresses draft §5/§6/§7, Wrap-Up, M3 route; NOT Standard Files, splits, ownership, Decision Drift Resolution) and the Human-Input-pinning note.
- [ ] **Step 3: Verify:** `grep -n "questions" plugins/codebase-scribe/commands/codebase-scribe.md | head -3`; `grep -n "proportional" plugins/codebase-scribe/skills/scribe-draft/SKILL.md`.
- [ ] **Step 4: Commit** — `git commit -am "scribe: citation/inventory standards, proportional claims, questions toggle (spec §7)"`

### Task 25: Autonomy removal

**Files:**
- Modify: `plugins/codebase-scribe/commands/codebase-scribe.md` — Step 0 heading + detection paragraph (~lines 29–34), 9d clause (~line 290), 9e condition 1 + detection paragraph + Precedence + option-set headings (~lines 313–344)
- Modify: `plugins/codebase-scribe/README.md` — "or autonomous runs" (~line 84)

- [ ] **Step 1:** Apply spec §8 exactly: heading → `### Step 0: Branching strategy`; 9d replacement quoted in full ("…if the change is `new_draft` or `major_rewrite`, proceed to 9e before finalizing. Otherwise, proceed directly to finalize (9f)."); 9e renumbered to conditions 1–2 with condition 2 in the spec §8 widened wording (this task is the SOLE owner of the widening — nothing was transcribed earlier); Precedence + both option-set headings rewritten; README phrase removed.
- [ ] **Step 2: Verify:** `grep -riE 'autonom(ous|y)' plugins/codebase-scribe --include="*.md" --include="*.sh" -l | grep -v eval | grep -v IMPROVEMENT-REPORT` → empty; manually confirm 9e's case numbers are self-consistent.
- [ ] **Step 3: Commit; open the wave-5 PR** — `git commit -am "scribe: remove autonomous-mode machinery (spec §8)"`

---

## Wave 6 — eval regeneration

### Task 26: Regenerate all four eval suites

**Files:**
- Modify/regenerate: `plugins/codebase-scribe/skills/{scribe-discover,scribe-draft,scribe-maintain,scribe-review}/eval.yaml`, `eval.md`, `eval/cases/**`

- [ ] **Step 1:** For each suite, regenerate cases and schemas against the post-wave-5 contracts (discover: stub creation from a provided topic list + docs_dir; draft: two-tier drafting with human_sections/claims/decisions; maintain: drift detection incl. scan validation and the shallow gate on seeded fixtures; scribe-review: seeded documentation errors — wrong-file attribution, deprecated-as-current, changelog language — exercised through the dispatching stub). Use the repo's `/eval-analyze` flow where it applies (it reads each SKILL.md).
- [ ] **Step 2:** De-P3 carve-out in scribe-review's suite: rewrite `recommendation_actionable`, the `outputs.schema` recommendation lines, `review_quality`'s prompt, and the corresponding `eval.md` text for the new recommendation strings. Keep runner config otherwise, including `claude-opus-4-6` model ids.
- [ ] **Step 3:** Remove every legacy fixture artifact: `grep -rln "inventory.yaml\|AGENT.md" plugins/codebase-scribe/skills/*/eval*` → empty after regeneration.
- [ ] **Step 3b: Per-suite acceptance check** — each regenerated suite has ≥ 5 cases (repo convention) and its `eval.md` names the spec sections its cases exercise (discover: §5 stub contract + collision refusal; draft: §1 two-tier + cross-cutting attribution + §4 claims/decisions; maintain: §2 validation/shallow/drift rows + §4 decision drift; scribe-review: §3 protocol via the stub dispatch). List any deliberately uncovered spec section in `eval.md`.
- [ ] **Step 4: Commit; open the wave-6 PR** — `git add plugins/codebase-scribe/skills && git commit -m "scribe: regenerate eval suites against shipped contracts (spec §9 wave 6)"` (`-a` cannot stage new case files; evals run manually post-acceptance per the fork workflow — the deliverable is runnable correctness.)

---

## Wave 7 — audit, cleanup, release

### Task 27: Cursor audit + README limitations section

**Files:**
- Modify: `plugins/codebase-scribe/README.md` — new "Known limitations in Cursor" section + Documentation Review section update

- [ ] **Step 1:** Audit in Cursor: AskUserQuestion (+multiSelect), hooks semantics (`$CLAUDE_PROJECT_DIR` availability), anything Task 13 didn't cover. Fix what is cheap; document the rest in the new README section.
- [ ] **Step 2:** Update the Documentation Review section: fresh-context agent description (now true), the no-model-pin rationale, review flow.
- [ ] **Step 3: Commit** — `git commit -am "scribe: Cursor audit results and limitations section"`

### Task 28: P4 sync check + version bump + P5 README re-read + cleanup

**Files:**
- Create: `plugins/codebase-scribe/scripts/check-sync.sh`
- Modify: both `plugin.json`, both root `marketplace.json` (1.2.6 → 1.3.0), `plugins/codebase-scribe/README.md`
- Delete: `plugins/codebase-scribe/IMPROVEMENT-REPORT.md` — a working-tree deletion only (the file was never committed, so no commit records it); this plan + spec stay committed

- [ ] **Step 1:** Write `check-sync.sh`: four-way version comparison (both plugin.json versions and both marketplace codebase-scribe entries identical) + — if Task 19 took the derived-copy fallback — a diff check that the skill copy matches its generation source. Exit non-zero on mismatch.
- [ ] **Step 2:** Run it (expect failure states verified by temporarily perturbing one file, then restore). Bump all four versions to 1.3.0. Run again: exit 0.
- [ ] **Step 3:** P5 README full re-read: align every behavioral claim (fresh-session review, `.claims.yml` "regenerable", gitignore automation, Standard Files list minus upstream, scan example note, `questions`/`default_branch` config, Human Input caveat, the recorded non-git-directory refusal under `main-only` (spec §2), version, Cursor section).
- [ ] **Step 4:** Delete `IMPROVEMENT-REPORT.md`. Final sweep: `grep -riE 'autonom(ous|y)|upstream' plugins/codebase-scribe --include="*.md" -l | grep -v eval` → empty.
- [ ] **Step 5: Commit; open the wave-7 PR** — `git add plugins/codebase-scribe .claude-plugin .cursor-plugin && git commit -m "scribe: v1.3.0 — sync check, README alignment, cleanup"` (`-a` cannot stage the new check-sync.sh).
