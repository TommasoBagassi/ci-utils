# codebase-scribe Improvements — Design Spec

- **Date:** 2026-07-27 (rev 4 — reworked after voting round 2: fresh voters E and F,
  both NOT_APPROVED; the full union of their findings is addressed in this revision)
- **Status:** Pending gate decision (see revision log)
- **Baseline:** fork `TommasoBagassi/ci-utils` @ `b3204c4` (identical to origin main as of this date)
- **Branch:** `scribe-improvements`
- **Background:** full findings analysis in `plugins/codebase-scribe/IMPROVEMENT-REPORT.md`
  (uncommitted working doc; wave 7 deletes it). This spec is self-contained.

## Context

codebase-scribe is a Claude Code / Cursor plugin that generates and maintains agentic
documentation (an `AGENTS.md` hub + topic files under a configurable docs directory,
default `docs/agents/`) for any codebase, in three phases: seed (stubs), draft (content
+ tribal-knowledge questions), maintain (drift detection). A 2026-07-27 review found
correctness and design defects; a parallel analysis of the plugin's one real deployment
(kiali/kiali — docs generated 2026-05-26 by an earlier plugin version, squash-merged in
kiali PR #9656) confirmed several failure modes in the field.

**Hard constraint:** kiali will run a `/codebase-scribe` completion run after this work
lands — defined as **after wave 3 at the earliest** (waves 1–3 close the drift-integrity
and review-pipeline changes; see §9). That run directly exercises scan-SHA validation
(§2), the structure contract (§1), the branch gate (§2), and the watch-path repair
(§2). Note: **kiali's default branch is `master`, not `main`** — the branch gate is
specified against the detected default branch for exactly this reason.

The plugin is **manually run** (no automation exists or is planned). **Cursor support
is real** (actively used); §3 carries a Cursor pre-check because of it.

## Goals

1. The review gate runs in genuinely fresh context, matching what the README claims.
2. User-sourced tribal knowledge survives clones, machine switches, and redrafts of
   the topic that holds it.
3. Drift detection cannot be silently disabled by the plugin's own bookkeeping
   (dangling scan SHAs, narrowed watch paths, off-default-branch generation) — and
   already-damaged deployments (kiali) are repaired, not just protected going forward.
4. Mature documentation with domain-specific structure is a first-class citizen.
5. One canonical copy of every internal contract (templates, protocols, orchestration).
6. Eval suites describe the architecture that actually ships.

## Non-goals

- No new features beyond the fixes and the repairs required by them.
- No change to the three-phase design. The three-score *formulas* are unchanged; one
  score's classification consequence changes (§2, `undercooked`) because keeping it
  would create an infinite redraft loop.
- No automation/cron support — the existing half-built autonomous machinery is removed.
- No Cursor feature parity — the goal is an audit, one targeted pre-check (§3), and
  honest documentation of gaps.
- **Custom `output.docs_dir` becomes genuinely supported** (advertised config today,
  hardcoded in ~30 places). In scope as a consistency repair. The `branch-local`
  strategy's docs_dir override is specified (§5) but `branch-local` itself remains
  as-is otherwise.
- **`branch-commit` residual, acknowledged:** the branch gate is `main-only`-scoped,
  so `branch-commit` still stamps feature-branch SHAs into `scan` and a squash merge
  still dangles them. The new scan validation converts that from silent breakage to
  self-healing (the topic classifies `drifted` with `freshness: 0` and redrafts) — at
  the cost of a spurious full-drift classification after every squash merge for
  `branch-commit` users. Accepted; not worth a strategy-specific mechanism now.

---

## Frontmatter key preservation (cross-cutting rule)

Several sections add committed frontmatter keys (`decisions`, `question_passes`;
`review_notes` already exists). **General rule, referenced by every writer: any
frontmatter key not explicitly named by a writer is carried through unchanged.**
Three writer-specific consequences:

1. **Draft §10's enumerated write list** ("YAML frontmatter (scan SHA = current HEAD,
   scores, inferred_sections, watch_paths, empty stale_flags)") is amended to add
   "…, and preserved verbatim: `decisions`, `question_passes`, `review_notes`, and
   any other keys present." Without this, the first `drifted` redraft destroys the
   data §4 exists to make durable.
2. **Human attribution survives redrafts:** `inferred_sections` IS explicitly named
   by draft §10, so the carry-through rule alone does not protect the `human_input`
   score. Added rule, keyed on **positive evidence, not list-absence**: when draft
   redrafts a topic, a top-level section slug stays out of the regenerated
   `inferred_sections` only if **the pre-invocation file was NOT a stub (§1's test)**
   AND the slug was absent from its `inferred_sections` AND the section's content
   survives into the redraft (extended, not replaced — if draft rewrites the
   section's content wholesale, its slug re-enters `inferred_sections`; the
   attribution is not a one-way ratchet). The not-a-stub conjunct is load-bearing: a
   discover-created stub has `inferred_sections: []` and all five headings, so a pure
   absence test would score every freshly drafted stub as 100% human input —
   inverting draft §8's "no user answers → score 0" rule and the README's "no false
   confidence" guarantee. `human_input` therefore cannot regress across a redraft of
   a mature topic unless the human-touched sections were removed or rewritten.
3. **Discover never overwrites:** discover refuses to write a topic file that already
   exists and reports the collision to the orchestrator instead. (Discover is
   reachable while mature topics exist — focus mode Step 6d and Step 8 row 7 both
   route new-topic proposals through it — and its "this EXACT format" stub write
   would otherwise destroy a mature topic on a kebab-name collision.)

**Acceptance:** redraft a mature topic carrying a `decisions:` entry, a
`question_passes` value, and one human-credited section; all three survive (the
section stays out of `inferred_sections`); **the first draft of a stub yields
`human_input: 0` when no questions were answered** (the not-a-stub conjunct); a
discover invocation naming an existing topic writes nothing and reports the
collision.

## §1. Structure contract (two-tier) — findings H7, M1

### Contract

- **Stub topics**: a topic whose body is empty or contains a line **beginning with**
  the stub placeholder marker (`*Stub — will be populated`), **ignoring lines inside
  fenced code blocks** — anchored and fence-aware so a mature topic that quotes or
  verbatim-reproduces the marker (e.g. documentation about this plugin's own
  templates) is not classified stub forever. The full 5-section skeleton is required at creation,
  unchanged (`Key Entry Points`, `Patterns & Conventions`, `Gotchas`, `Dependencies &
  Context`, `Links`, plus TL;DR blockquote).
- **Mature topics**: any topic that is not a stub by the test above. The test is
  locally decidable — hook, maintain, and draft apply it to file content alone. For
  mature topics the **TL;DR blockquote is mandatory**, defined positionally: **after
  the closing `---` of YAML frontmatter**, the first non-blank line following the
  first `# ` heading line must begin with `>`. A file with no `# ` heading at all is
  flagged as missing its TL;DR. A **`## Links` section is strongly suggested** but
  not required. Free-form domain headings (e.g. kiali's "Graph Data Model") are fully
  legitimate and tracked via `inferred_sections` as today.
- **One stub test everywhere:** command Step 5's `stub` row currently reads "Body
  empty/<50 words, or placeholder text, or has `migration_source`". Rewritten:
  "body is empty or contains the anchored stub placeholder marker, or has
  `migration_source`" — the `<50 words` conjunct is dropped. (Without this, a 30-word
  hand-authored topic is simultaneously mature to the hook, `stub` to Step 5, and
  `undercooked` to §2.) Two clarifications: the `migration_source` disjunct is a
  Step-5-only *routing* signal (a migrated topic must be drafted), intentionally
  absent from the hook's and the contract's *maturity* test; and dropping the word
  count is an **accepted regression** for one rare state — a draft truncated after
  writing a short real body AND a valid `scan` now lands on the `current` default —
  with maintain §7's structural and actionability checks as the advisory backstop.

### Enforcement split

| Layer | Enforces |
|---|---|
| Hook (`doc-validate.sh`) | On mature topics: TL;DR presence only, positional definition above (replacing `grep -q "^>"`, which matches any blockquote anywhere). On stub topics: the 5-section skeleton (locally decidable, so the hook keeps today's section loop for stubs — otherwise the skeleton requirement would be enforced by no layer). **The existing `*/STATUS.md` exclusion survives the rewrite** (STATUS.md is machine-generated with none of the required elements). Silent about Links. |
| Maintain quality checks (scribe-maintain §7) | Flags missing TL;DR; advisory note for missing Links section. §7's "Verify each topic file has these 5 `##` headings" is rewritten to the two-tier contract. |
| Review agent | `MISSING_XREF` stays a minor finding (existing tier — no change). |
| Draft | Always writes TL;DR and a Links section in content it generates. **Four** sites are rewritten to the two-tier contract: §3's "no exceptions, no alternative layouts" structure rule; the Content standards rule "**Every topic MUST have all 5 sections**" (scoped after the rewrite to content draft generates for a *stub*); the §12 validation checklist; and Rework Pipeline step 8 (restates the §12 checklist and would otherwise fail-loop reworks on mature domain-headed topics). |

### Hook fixes (bundled here — same file)

- `hooks.json` matcher: `Write|Edit` → `Write|Edit|MultiEdit`. (Verify at
  implementation whether `MultiEdit` still exists; harmless future-proofing if not —
  no acceptance criterion depends on it.)
- TL;DR check: anchored positional check per the Contract (frontmatter skipped;
  no-heading files flagged).
- docs_dir awareness: resolve `.scribe.yml` from `$CLAUDE_PROJECT_DIR`, falling back
  to the current working directory. Extraction without a YAML parser, specified: match
  an **indented `docs_dir:` line inside the `output:` block** (not any `docs_dir:`
  under any parent), strip surrounding quotes and trailing comments; default
  `docs/agents` on any failure. A `docs_dir` with a leading `/` is used as an exact
  path prefix. The path match must accept both absolute and repo-relative `file_path`
  values (the current `*/docs/agents/*.md` pattern requires a leading `/` and never
  matches repo-relative paths). Known, documented gaps: the hook cannot see the
  `branch-local` runtime override (§5), so topics under `.scribe/branch-docs/` are
  not validated; and `$CLAUDE_PROJECT_DIR` availability in Cursor is unverified until
  the wave-7 audit — its absence degrades to the cwd fallback and then the default
  path, which is today's behavior.
- jq handling, with explicit precedence: prefer `jq`; if absent, extract `file_path`
  with grep/sed; if extraction yields nothing, exit 0 silently. No stderr noise on
  any path.
- Warning text becomes advisory (drop "Fix before proceeding").

**Acceptance:** a mature topic with domain headings and a TL;DR passes hook + maintain
with no structural warnings; a mature topic whose only blockquote is inside a later
section (no TL;DR) is flagged by both, as is a topic file with no `# ` heading; a stub
missing a skeleton section is flagged by the hook; STATUS.md is never flagged; the
hook validates files under a custom `output.docs_dir` given both absolute and relative
paths; running the hook script without jq on PATH produces no stderr output; no site
in draft or maintain (including all four draft sites and maintain §7) requires all
five headings of a non-stub topic; command Step 5's stub row contains no word-count
test; a mature topic quoting the stub marker mid-prose is not classified stub.

## §2. Drift integrity — findings H6, H3, M7

### Default-branch detection (prerequisite for the branch gate)

The plugin never hardcodes `main`. Detected once per run by the orchestrator, with a
**fail-closed** ladder — `refs/remotes/origin/HEAD` is written by `git clone` but not
by `git remote add`, and is absent in CI checkouts, so its failure must not be treated
as "no remote":

1. `.scribe.yml` `default_branch`, if set — overrides everything. (Flat key,
   consistent with the existing flat `branching_strategy`; added to the command's
   Error Handling defaults list — default: auto-detect — and the README config block,
   alongside §7's `questions`.)
2. `git symbolic-ref refs/remotes/origin/HEAD` (strip the prefix).
3. Probe `git rev-parse --verify origin/main`, then `origin/master`.
4. If a remote exists but none of the above resolves: under `main-only`, **refuse the
   run** and tell the user to set `default_branch` — never fall back to the current
   branch, which would compare the branch against itself and pass the gate on exactly
   the feature-branch runs it exists to block. Under `branch-local`/`branch-commit`,
   an unresolved default branch is passed as null and the branch guards are inert
   (they are `main-only`-scoped anyway).
5. Only when no remote exists at all (Error Handling #6): fall back to the current
   branch.

**Threading (the skills never re-detect):** the orchestrator passes `default_branch`,
`branching_strategy`, and `current_branch` in every skill brief — mirroring §5's
`docs_dir` threading. On a detached HEAD: under `main-only` the run refuses (below);
under `branch-local` it proceeds with `current_branch` set to the HEAD SHA; under
`branch-commit` it refuses (committing onto a detached HEAD is never intended).

**Error Handling section updates (all in the command):**
- Preamble gains "…except where an entry below explicitly refuses the run."
- Entry #5 (detached HEAD) rewritten per the strategy split above.
- A new entry covers scan validation (below), including its shallow-clone interaction
  with entry #4.

### Scan-SHA validation (H6)

At orchestrator Step 3 (frontmatter read), every topic's **non-null** `scan` value is
validated. **`scan: null` is never a validation failure** — it is handled exclusively
by the Step 5 rows below.

- **Shallow-clone gate first — covering every stored-SHA consumer:** if
  `git rev-parse --is-shallow-repository` is `true` (fallback for git < 2.15:
  `test -f .git/shallow`), skip scan validation AND all diff-based classification and
  maintenance branches (Step 5's classification diff, maintain §1 **and its §2 drift
  table, which consumes §1's churn number and has no input without it**, maintain
  §4/§5/§8, the Step 4 session-SHA check) and warn once, per Error Handling #4.
  Topics classify from body and frontmatter state alone; no frontmatter is degraded;
  freshness holds its last recorded value (covered by the warning) — **except for
  topics actually drafted this run**: `freshness: 100` on content just generated from
  current HEAD is a true assertion at any clone depth, so draft §8/§10 and 9f stamp
  it normally for drafted topics. (An earlier revision suppressed 9f's stamp under
  the gate; that held 9f and the writer of record — draft — to different rules for
  the same value, and the value is truthful. Undrafted topics simply keep their last
  freshness, which the warning covers.)
- **Shape:** must match `^[0-9a-f]{7,40}$` (the README's example `"a1b2c3d4"` stays
  valid; the literal `"HEAD"` fails).
- **Resolution and reachability:** `git cat-file -e <sha>` AND
  `git merge-base --is-ancestor <sha> HEAD` — the reachability test catches
  unreachable pre-squash objects that still exist on the authoring machine, which
  would otherwise make the same topic `current` on one clone and `drifted` on another.

On validation failure (non-null values only): the topic classifies `drifted`, never
`current`, and **its frontmatter `freshness` is set to 0 immediately at Step 3**,
before any STATUS.md regeneration — every STATUS.md writer (draft's regeneration
step, maintain §10, command Step 10, command 9f item 6, and discover on seed)
**sources its scores from frontmatter**, so the degraded value must be persisted
where they read.

**Step 5 row rewrites — the rules, not just the outcomes** (five rows change — two
of them owned by §1 and §4 respectively; the replacement text is normative):

| Row | New criterion |
|---|---|
| `stub` | body empty or anchored stub marker, or has `migration_source` (§1) |
| `drifted` | **`scan` is non-null** AND (watch_paths changed since scan SHA OR scan validation failed). Step 5's header diff command is skipped for null-scan topics. |
| `undercooked` | `scan` is null AND the body is not a stub (never successfully drafted — crashed-draft/hand-authored case, at any completeness score) |
| `unverified` | `human_input == 0` AND `freshness >= 40` AND `question_passes < 2` AND `questions` is not `false` |
| `current` | **no other row matched** (true default — "scores adequate + scan matches HEAD" is dropped) |

Topics that completed a draft are never auto-redrafted for low completeness; low
scores surface in STATUS.md and as review `COVERAGE_GAP` minors. The forced-redraft
path remains maintain §9's escalation (`escalated` flag + `completeness: 0`), and
maintain §9 step 1's parenthetical is rewritten to name the `escalated`
classification.

**Other stored-SHA consumers, all guarded** (outside the shallow gate, i.e. in full
clones): maintain §1/§4/§5 (`flagged_at_sha`)/§8 treat an unresolvable/unreachable
SHA as full churn and skip their diff-based branches; **command Step 4** discards a
session whose `last_active_sha` fails the same test; `_meta.<topic>_extracted_at`
needs **no** guard (equality-compared only; mismatch triggers re-extraction — the
safe direction).

### watch_paths: directories forever, plus a one-time repair (H3)

- Draft's §9 ("Update Watch Paths") is **deleted**: draft NEVER narrows watch_paths.
- **Repair (required for kiali), by path shape, not filesystem state:** at Step 3,
  for every watch_paths entry: normalize trailing slashes first; then, **iteratively
  until the entry resolves to an existing directory or is reduced to a single
  segment**, replace it by its parent (the normalized path minus its last
  `/`-segment); dedupe the result. (One replacement per run would take a
  `pkg/gone/sub/file.go` entry three runs to converge, changing the drift scope and
  completeness denominator each time — the loop makes run 1's output a true fixed
  point, and the repair genuinely idempotent.) **Single-segment entries are preserved
  as-is** — root-level files (`Makefile`) and top-level directories (`frontend/`
  renamed to `web/`) alike, whose "parent" would be the repo root; a `.` watch path
  would drift on every commit forever. **Preserved single-segment entries that do not
  resolve to an existing directory or file are reported in the Step 13 summary** —
  they are permanently drift-blind scopes, and silence about them would recreate
  Goal 3's failure mode with the spec's own blessing. The repair is purely
  mechanical: frontmatter records no provenance, so subdirectory entries are widened
  regardless of origin; root-level entries preserved regardless of origin.

### Branch gate (M7)

Two layers, both **conditional on `branching_strategy: main-only`**:

1. Step 0's existing check (already an exit today; this is a wording hardening) gets
   explicit refusal wording, comparing against the **detected default branch**.
2. Finalization refuses to update **both `freshness` and `scan`** when the current
   branch is not the default branch, at **every stamping site**: command 9f; draft
   §8/§10; draft Rework step 6; maintain §8; **and, for the wave-1 window before §3's
   M2 reduction deletes them, the two Review Gate restatements** (draft's "update
   scan SHA" line and maintain §12's "finalize (9f)" line get the same one-sentence
   guard in wave 1 — they are deleted in wave 3 anyway, but wave 1 is the
   kiali-blocking wave and ships first). The skills read branch state from the brief
   (threading above), never re-detect.

**Acceptance:** a repo with dangling, unreachable, or `"HEAD"` scan values classifies
those topics `drifted` with `freshness: 0` persisted; a shallow clone skips
validation and all diff branches with one warning, degrades nothing, and never stamps
`freshness: 100`; a topic with `scan: null` and a real body classifies `undercooked`
(the `drifted` row's non-null conjunct makes this decidable, not just asserted); a
session with a dangling `last_active_sha` is discarded; the watch-path repair
converges in one run (iterative widening), preserves single-segment entries, and
reports dangling ones; committing a new file into a watched directory classifies the
topic drifted next run; a `main-only` run on a non-default branch refuses at Step 0
and every stamping site refuses if reached; a `branch-local` run still finalizes; a
fully-drafted topic with completeness 20 classifies `current`.

## §3. Review pipeline — findings H1, M2, M4, P3

### scribe-review becomes a plugin agent (H1)

- New `agents/scribe-review.md`: frontmatter (`name`, `description`,
  `tools: Read, Bash, Grep, Glob`), system prompt = the **merged** content of
  `skills/scribe-review/SKILL.md` + `skills/prompts/review-adversarial.md`,
  preserving both divergence directions (SKILL.md's Scoped Re-Review + "if in doubt →
  REWORK_NEEDED"; the prompt's "Common LLM Documentation Errors" + changelog-language
  rule).
- **Brief contract, both sides changed together:** the brief is passed as the Agent
  tool's **prompt** (the Agent tool has no `args` parameter — 9c's and 9d item 3's
  "pass as `args`" phrasing is rewritten). 9c's `source_files` block becomes **paths
  only** (the 500-line excerpt clause is dropped); the merged agent prompt's Inputs
  section is rewritten to match.
- **Dispatch identifier — verified, not assumed:** the repo's only working precedent
  (`plugins/code-reviewer/commands/review.md`) dispatches plugin agents by **bare
  name** (`adversarial-reviewer`), not a namespaced form. The Cursor pre-check below
  therefore also verifies **the exact `subagent_type` string a plugin agent is
  addressed by, in both Claude Code and Cursor**. The spec uses
  `codebase-scribe:scribe-review` in its text; if the bare `scribe-review` is what
  resolves, all four dispatch sites and the acceptance criteria use the bare form.
  This cannot be left to runtime discovery: §3 deletes the skill fallback, so a wrong
  identifier is a dead review pipeline.
- **No `model` pin** — inherits the session model; rationale documented in the
  README's Documentation Review section (agent markdown has no comment syntax; an
  HTML comment would enter the system prompt).
- `skills/scribe-review/SKILL.md` and `skills/prompts/` are **deleted**; the eval
  tree (`eval.yaml`, `eval.md`, `eval/cases/**`) is **relocated in the same wave** to
  `plugins/codebase-scribe/evals/scribe-review/` so no wave leaves a dangling
  `skill:` reference under `skills/`.
- **Dispatch sites, enumerated:**
  1. Command Step 9c — including its trailing sentence naming both deleted files.
  2. Command Step 9d item 3 (scoped re-review after rework).
  3. Draft's Review Gate (reduced; below).
  4. Maintain §12 (reduced; below).
  Each becomes: "dispatch the `codebase-scribe:scribe-review` agent [or bare name per
  the pre-check] via the Agent tool, passing the brief as its prompt — do NOT
  hand-write a review prompt for a generic agent."
  **Step 8's sub-skill rule is preserved in substance, with a scope clause added**;
  replacement text: "Always use the `Skill` tool to invoke the draft and maintain
  sub-skills — do NOT spawn a general-purpose `Agent` with a hand-written prompt that
  replicates a skill's behavior. (Review dispatch is the exception: it uses the
  dedicated scribe-review agent — see Step 9c.)"
  **Step 9's preamble is updated too:** its second sentence ("The skills reference
  the substeps below directly") becomes "The skills invoke Step 9 as a whole via
  their Review Gate pointers."
- **M2 dedup, reinstated** (rev 2's "they only point at Step 9" was a false premise —
  both sections restate substeps 9a–9f, including a third "update scan SHA" statement
  and a divergent stub-check rule): draft's Review Gate and maintain §12 are each
  reduced to a pointer. **Draft's version RETAINS its current first line** — "Skip
  this section when in rework mode — the orchestrator handles scoped re-review via
  Step 9d." — a guard, not a substep restatement (without it a reworked draft
  dispatches a nested review from inside 9d's cycle, recursing outside the
  2-iteration cap). Draft's reduced text: "Skip this section when in rework mode —
  the orchestrator handles scoped re-review via Step 9d. Otherwise: follow Step 9
  (Review Orchestration) in `commands/codebase-scribe.md` for every topic modified in
  this pass — dispatching reviews via the scribe-review agent as Step 9c specifies —
  and return to the orchestrator only after it completes for all of them." (Maintain
  has no rework mode; its version omits the first sentence.) Substeps 9a–9f then
  exist only in the command.
- **Recommendation lines (P3):** the referenced slash commands do not exist. Signal
  kept, fake commands removed: "Run `/codebase-scribe` again — targeted correction of
  sections: <list>." vs "Run `/codebase-scribe` again — full redraft recommended."
  The reviewer guidance paragraph stays.
- **9d escalation mapping (renumbered 9e):** 9e's condition 2 is **widened to match**
  — "the rework loop escalated: cap exhausted, same finding persisted, or new
  critical findings appeared" — so that all three 9d escalation routes satisfy the
  condition whose option set (case 2, no "Request changes") they present. (Without
  the widening, "new critical findings" at iteration 1 would reach 9e matching no
  condition. This ambiguity predates the spec; §8's renumbering is where it gets
  resolved.)

### Cursor pre-check (gate for the skill deletion)

Before `skills/scribe-review/SKILL.md` is deleted, verify **three things**: (1) in
both Claude Code and Cursor, plugin-defined agents are dispatchable at all
(`plugins/code-reviewer/agents/` ships three agents through this marketplace —
precedent, not proof); (2) the exact `subagent_type` identifier that resolves
(namespaced vs bare — see Brief contract above); (3) **whether the eval harness
discovers suites outside `skills/*/eval.yaml`** — the eval-tree relocation happens
in this same wave, and if discovery globs `skills/`, the relocated suite would be
silently unfindable for three waves, not "stale but present". If (1) or (2) fails in
Cursor, stop and surface the decision. The full Cursor audit remains wave 7; these
questions cannot wait, because §3 removes the fallback and moves the suite.

### Snapshots to disk (M4)

- **Step 8 deletes `.scribe/snapshots/` and rewrites it at the start of every run.**
  Snapshot scope: for a draft invocation, the batch; **for a maintain invocation,
  every topic in the docs dir** (maintain touches topics through mechanical fixes,
  claim re-extraction, flag lifecycle, and score updates — an unsnapshotted modified
  topic would fail into `major_rewrite` and fire a human gate per topic). Per topic:
  `.scribe/snapshots/<topic>.md` (full file including frontmatter),
  `<topic>.claims.yml`, `<topic>.headings.txt`.
- **9a item 1 keeps today's semantics:** it reads the pre-skill `scan` value **from
  the snapshot's frontmatter**. Sentinel disambiguation (the two states are
  distinct): a **zero-byte** snapshot is the deliberate marker Step 8 writes for a
  topic file that did not exist — 9a classifies `new_draft`; an **absent** snapshot
  for a topic that was nonetheless modified means Step 8 failed to cover it — 9a
  classifies `major_rewrite` (fail toward review, never away from it).
- Step 9a diffs the on-disk snapshot against the current file (`git diff --no-index`
  or equivalent).
- **Before writing snapshots, Step 8 verifies the target repo's `.gitignore` covers
  `.scribe/` and creates the entry if missing** (belt-and-braces with §4's seeding).

**Acceptance:** no reference to scribe-review as a *skill* remains under `commands/`
or `skills/` at the end of the §3 wave; the review protocol exists in exactly one
file; all dispatch sites use the Agent tool with the verified identifier and the
brief as prompt; Step 8's sub-skill rule and Step 9's preamble are updated as quoted;
substeps 9a–9f exist only in the command; a rework cycle's re-review dispatches the
agent and never recurses (guard retained); the first draft of a discover-created stub
classifies `new_draft`; a modified topic with an absent snapshot classifies
`major_rewrite`; a maintain run snapshots every topic; snapshots never survive across
runs; recommendation lines name only `/codebase-scribe`.

## §4. Knowledge persistence — findings H2, M9, M3

### Provenance in frontmatter (H2)

Topic frontmatter gains a committed `decisions:` list under `scribe:`:

```yaml
scribe:
  decisions:
    - id: backend-architecture-12
      type: technology
      claim: "PostgreSQL chosen over MongoDB for ACID support"
      context: "MongoDB rejected for lack of ACID; SQLite rejected for no vector search"
      recorded: "2026-05-04"
      source: "internal/store/postgres.go"
      status: active   # active | retired
```

- Preservation across redrafts: the cross-cutting rule (top of spec).
- **Write timing (ids exist only after extraction):** draft §6/§7 record the answer
  and its context in working state; the `decisions:` entry — with its id — is written
  at **§11 (Extract Claims), immediately after the corresponding claim is extracted
  and assigned its id**. Draft §11's sequential assignment skips ids named in
  frontmatter `decisions:` (active and retired), alongside its existing
  `_retired_ids` skip. (Writing the entry at §6 would require an id that does not
  exist yet; guessing one collides with §11's own assignment.)
- **Answer incorporation target (also fixes draft §6/§7's current wording):** append
  to `Dependencies & Context` or `Gotchas`; **if neither exists, append to the last
  `##` section; if the topic has no `##` section at all (a TL;DR-only mature topic),
  create `## Dependencies & Context` and append there.** Slug handling per HARD
  RULE 4: if the target section is in `inferred_sections`, remove it (raising
  `human_input`); if it is not — a genuinely hand-authored section, already counted
  as human — no list change occurs and no score change is expected. (`human_input`
  is 0 when a topic has zero sections.)
- **Re-linking (maintain §6), by content, never by id:** a re-extracted claim
  matching an `active` decision entry on `{type, topic, first-50-chars}` gets
  provenance restored and takes the entry's id. Uniqueness guards: many-claims-to-one
  → first in document order binds; one-claim-to-many → binds none, decisions reported
  unmatched. **Residual, accepted:** a reworded claim can fail the match and drop the
  link — fail-safe (lost, never grafted); maintain reports unmatched active
  decisions.
- **Retirement is a tombstone:** all three Decision Drift Resolution outcomes write
  frontmatter first; "No longer relevant" sets `status: retired` (kept — deletion
  would let re-linking resurrect it). Retired entries are skipped by re-linking and
  decision-drift detection.
- Decision drift detection (maintain §4) reads frontmatter `decisions:`
  (`status: active` only).
- `.claims.yml` stays gitignored (user decision 2026-07-27). README updated: now
  truthfully regenerable.
- **Migration for already-tracked caches (kiali) — owner: command Phase 0 Step 1,
  immediately after gitignore seeding.** Trigger: **solely trackedness**
  (`git ls-files --error-unmatch <docs_dir>/.claims.yml`) — not "decisions already
  exist", which would leave a crash-interrupted migration permanently half-done.
  Reconstruction is **per-decision idempotent** (skip any decision whose
  `{type, topic, first-50-chars}` already exists in that topic's `decisions:`), so a
  resumed migration completes the remaining topics. Then `git rm --cached`. The
  staged untrack AND any `.gitignore` modification are **reported in the Step 13
  summary with an explicit instruction to commit them** (the plugin does not commit;
  an uncommitted staged deletion a user resets would silently re-track the file).

### Orchestrator-owned .gitignore seeding (M9)

**Owner: command Phase 0 Step 1** (NOT discover — HARD RULE 2 forbids it writing
outside the docs dir). Idempotent append of `.scribe/` and `<docs_dir>/.claims.yml`
(skip if present; create the file if absent; **skip the claims entry when the
resolved docs_dir is already under an ignored path** — under `branch-local` the
resolved dir is `.scribe/branch-docs/`, covered by the `.scribe/` entry). §3's
snapshot writer performs the same check as a guard.

### Question-pass for unverified topics (M3)

Same explicit contract shape as rework mode:

- **Selection:** Step 8's `unverified` row invokes draft with `question_pass: true`
  in the brief (batched). The Step 5 `unverified` row criterion is in §2's table.
- **Pipeline:** ask the §6 question; on an answer, append per the incorporation rule,
  update `inferred_sections` per HARD RULE 4, recompute `human_input`, extract the
  claim + write the `decisions:` entry (at §11 per the write-timing rule); increment
  `question_passes` (the pass writes the increment, answered or skipped). Output
  flows through Step 9 like any draft output (typically `claim_change`).
- **NOT done:** reading source files; regenerating any existing section; focus-mode
  or critical-gap questions; the Standard Files block.
- **Settling and the two resetters, precedence stated:** at `question_passes: 2` the
  topic stops classifying `unverified` (the §2 row). Reset to 0 is written by **9f**
  when the just-computed 9a classification is `new_draft` or `major_rewrite`. The
  draft-side fallback is **strictly a fallback, active only on the two 9f-bypassing
  paths** (`review.enabled: false`, or the user chose skip at 9b): on those paths
  only, draft resets the counter for a topic it fully redrafted. **Timing:** under
  `review.enabled: false` the reset applies at finalization of the redraft; on the
  9b-skip path — knowable only after Step 9 runs — draft writes the reset after
  Step 9 returns for that topic. (In practice the 9b path is nearly unreachable for
  full redrafts: they classify `new_draft`/`major_rewrite`, which the default
  `auto_trigger` always reviews — the branch exists for customized `auto_trigger`
  configs.) The fallback is NOT active when 9f runs for the topic — otherwise a full
  redraft that 9a then classifies `claim_change` would have already reset the
  counter that 9f deliberately declines to reset, re-opening the settled loop for a
  consistently-skipping user on churny topics.
- **`questions: false` (§7):** the M3 route is suppressed; the §2 row's
  `questions`-conjunct makes such topics classify `current`.

### Orchestrator visibility

Command Step 3's frontmatter-extraction list adds: `decisions`, `question_passes`.

**Acceptance:** delete `.claims.yml`, run maintain on a repo with frontmatter
decisions → decision drift works, provenance re-links by content with both
uniqueness guards, retired stays retired; an answer on a TL;DR-only topic creates
`## Dependencies & Context` and is recorded in `decisions:` (human_input does not
regress; it rises when the target section was machine-attributed); ids are assigned
only at §11 and never collide with decision-reserved ids; the kiali migration
triggers on trackedness alone, resumes cleanly after interruption, and reports both
the staged untrack and the `.gitignore` change; an unverified topic settles at 2
passes, and a settled topic redrafted through a running Step 9 stays settled unless
9a classifies `new_draft`/`major_rewrite`; Step 3 extracts the two new fields.

## §5. Discover and hub management — findings H5, M10, P7

- **Discover creates stubs + STATUS.md only**, in the brief-supplied `docs_dir`
  (both paths hardcoded today); it **refuses to overwrite existing topic files**
  (cross-cutting rule #3). Hub paragraph, template sentence, and AGENTS.md
  instructions deleted; HARD RULES become internally consistent.
- **AGENTS.md creation collapses to one path: command Step 12**, via a new canonical
  template block **`#### 12f: Hub template`**. No template exists today to copy —
  discover's line 75 is a one-sentence *list of section names*, and the only concrete
  template (Step 1's orphan three-item one) is deleted — so **12f's body is newly
  authored to the five-part outline and specified here**:

  ```markdown
  <!-- scribe:managed -->
  # <Project Name>

  <one-line project description, from README or build metadata>

  ## Quick Reference

  | Action | Command |
  |--------|---------|
  | Build | `<build command>` |
  | Test | `<test command>` |
  | Run locally | `<run command>` |

  ## Architecture at a Glance

  <top-level directory tree, one line per significant directory with its purpose>

  ## Documentation

  - [<Topic Title>](<docs_dir>/<topic>.md) — <topic TL;DR>

  ## Conventions

  Conventions are documented per topic — see the Documentation links above.
  ```

  Population: project name/description from README (or build-file metadata);
  commands from root build files; unknown cells say "see build files". The
  ARCHITECTURE.md pointer line (`> For the full architecture index, see
  [ARCHITECTURE.md](ARCHITECTURE.md).`, under Architecture at a Glance) is included
  when that file exists at write time — **and 12d adds it later, in full-management
  mode only, under the Architecture at a Glance heading if present** (append-only
  mode is restricted to the Documentation section and may lack that heading; a
  seed-time hub would otherwise never gain the link, since drafting creates
  ARCHITECTURE.md after the hub).
  Three call sites route here: 12b option 1, 12c "Does not exist", 12e option 1
  (Step 1's orphan generator is deleted; orphan mode routes to 12c). **Identity-read
  allowance for call sites where Step 2 never ran:** both the 12c creation path
  (orphan mode) AND 12b option 1 (`agents_md_policy: manual`, file deleted, normal
  run) read the repo README and root build file before instantiating 12f (bounded:
  those two reads only).
- **Migration-mode ordering (regression guard):** the seed-flow change routes
  Migration mode through Step 12 in the same run, and 12e option 1 renames the very
  file that pending topics' `migration_source` points at — draft would later read a
  fresh scribe hub instead of the user's original content. Rule: **when 12e option 1
  creates a backup, it also rewrites every topic frontmatter whose unconsumed
  `migration_source` names the renamed file to point at the backup filename.** Draft
  then consumes the original content from the backup, as intended.
- **Seed-run flow made explicit:** after Step 2d, the seed run continues to Steps
  10–13. **Step 2d's "Stubs created…" message is deleted; Step 13's next-action line
  is the single authoritative message.**
- **Documentation-heading match (M10), one rule applied uniformly:** prefer an exact
  `## Documentation` heading; otherwise the first `##` heading containing
  "Documentation" (case-insensitive); create `## Documentation` only when neither
  exists. Applies to 12d (both variants), 12d's create-if-missing branch, and 12e
  option 2. **The marker-placement sentence applies to 12e option 2 only** (12d
  operates on files that already carry a marker): 12e option 2 places
  `<!-- scribe:managed:append-only -->` directly above the matched heading. Residual
  risk accepted: containing-match can select an unintended section in hubs with
  several Documentation-like headings; exact-match preference and document order
  bound this.
- **Stale-content refresh (P7):** full-management mode removes lines exactly matching
  the known legacy footer strings — both variants: `Run /codebase-scribe again to
  draft content for these stubs` / `…for the stubs` (with or without backticks) — and
  only when no stub topics remain. **Evidence status:** the strings are field data
  from the kiali hub, not derivable from current sources (nothing in the plugin
  writes a hub footer today — Step 2d/13 print to console). The exact strings are
  **verified against the kiali hub at implementation time**; being exact-match, a
  wrong string is a silent no-op, and the related acceptance criterion is conditional
  on that field verification.
- **docs_dir threading:** all remaining hardcoded `docs/agents` references in
  behavioral instructions become "the configured docs_dir (default `docs/agents`)":
  command Steps 3 and 10, **command 9f item 6, and the command preamble**; draft's
  claims path, STATUS.md regeneration, README-generation links; maintain's claims
  path, STATUS.md, standard-files link checks. (Step 12's link matching is already
  generic.) The command resolves `docs_dir` once in Phase 0 and passes it in every
  skill brief. **`branch-local` precedence:** Step 0's override
  (`.scribe/branch-docs/`) wins; Step 3's mismatch warning is suppressed under
  `branch-local`; the hook cannot see the override (documented gap, §1).

**Acceptance:** a seed run with custom `output.docs_dir` puts stubs and STATUS.md
there and subsequent runs read/write the same directory with no mismatch warning
(threading enumeration illustrative; catch-all authoritative — also covers draft's
ARCHITECTURE.md generation links, discover's HARD RULE 2 path constraint, and the
merged review agent's cross-topic check); a fresh seed run leaves an AGENTS.md
instantiated from 12f (unless `agents_md_policy: none`) and prints exactly one "run
again" message; a migration-mode run that replaces AGENTS.md leaves every pending
`migration_source` pointing at the backup, and the next draft consumes the original
content; deleting AGENTS.md while keeping the docs dir routes through 12c with
README-sourced identity; grep finds no "discover skill's hub template" reference; a
hub whose only section is `## Architecture Documentation` gets links appended there
by both 12d and 12e paths, marker (12e only) above that heading; a scribe-managed hub
with a field-verified legacy footer and no remaining stubs has exactly that line
removed; a seed-time hub gains the ARCHITECTURE.md pointer once the file exists.

## §6. Standard Files and the #39 strip — finding D5

- **Strip** (org-specific Red Hat directive content), complete list: draft Step A's
  upstream-detection block; its `docs/upstream.md` classification rules; **Step A's
  file-enumeration entry for `docs/upstream.md` (including the "or `docs/` for
  upstream.md" parenthetical)**; Step B's upstream question text and prompt-order
  entry; the `docs/upstream.md` template in Step C (including its rules block);
  the upstream link rule in ARCHITECTURE.md generation; the `docs/upstream.md`
  mention in command Step 13's summary line.
- **One isolated, cleanly revertible commit**, landing **before** P2's rework of
  Step B (both touch the same prompt loop; a revert after batching would re-add a
  sequential prompt into a multiSelect flow — the commit message notes that a future
  revert re-adds upstream as a multiSelect option).
- **Eval fixtures are permanently excluded from the upstream grep** — under both
  `skills/**/eval/` and `evals/**` (post-relocation). Known legitimate matches:
  `case-004-operator-audience` (reverse-proxy `UPSTREAM_URL` / "upstream pool"
  content) **and `scribe-review`'s `case-001-fresh-up-to-date/AGENT.md` ("an
  upstream API gateway")** — neither related to `docs/upstream.md`.
- **Keep:** README/CONTRIBUTING/ARCHITECTURE handling and the CLAUDE.md/GEMINI.md
  redirect stubs.
- **Prompt batching (P2, after the strip):** the sequential per-file prompts become
  at most 2 multiSelect AskUserQuestion calls (grouping is an implementation choice).

**Acceptance:** no mention of upstream.md or upstream detection remains in command,
skills, hooks, or README (fixtures excluded as above); `git show <strip-commit>`
touches only upstream-related content; strip commit predates the P2 commit; Standard
Files asks at most 2 questions.

## §7. Content standards — findings M8, P1, P6

- **Citations:** cite `symbol in file`, never bare line numbers. (Kiali: the
  symbol-anchored backend doc survived 35 commits at 9/10 accuracy; line-number
  citations were off by 1–3 lines at generation time.)
- **Volatile inventories:** never enumerate dependency lists, state shapes, or
  version pins unless review mechanically re-verifies them each run — describe where
  the inventory lives. (Kiali: frontend errors clustered entirely in inventory
  sections.)
- **Claims (P1):** "up to 15–20, proportional to content — do not pad small topics."
- **Questioning (P6):** §6 may ask zero questions when only a conventional-choice
  fallback remains. `.scribe.yml` gains top-level `questions: true`. `false`
  suppresses: draft §5, §6, §7, the Wrap-Up Pass, and the §4 M3 route. NOT
  suppressed: Standard Files prompts, split proposals, Step 12 ownership prompts,
  Decision Drift Resolution (maintaining existing user data, not soliciting new).
  Default added to the Error Handling defaults list and README config block, with the
  note that disabling questions pins Human Input at its current value.

**Acceptance:** draft SKILL.md contains the citation and inventory rules; the forced
one-question rule is conditional; `questions` and `default_branch` appear in the
defaults list and README config block (with the Human Input caveat); the suppression
list is stated in the draft skill.

## §8. Removals — finding M5

All autonomous-mode machinery is deleted:

- Step 0's "Autonomous detection" paragraph; **Step 0's heading renamed** to
  "### Step 0: Branching strategy".
- Step 9d's autonomous clause — replacement text quoted in full, **including the
  surviving second half**: "Then check whether the human gate (9e) should fire: if
  the change is `new_draft` or `major_rewrite`, proceed to 9e before finalizing.
  Otherwise, proceed directly to finalize (9f)." (Dropping the whole sentence pair
  would orphan 9e's surviving condition AND the PASS path's route to 9f.)
- Step 9e trigger condition #1 and its detection paragraph, with renumbering: 9e's
  conditions become 1 (new_draft/major_rewrite) and 2 (**the rework loop escalated:
  cap exhausted, same finding persisted, or new critical findings appeared** — the
  widened wording from §3, so all three 9d escalation routes satisfy it); the
  Precedence paragraph and both option-set headings rewritten; README's "or
  autonomous runs" removed.

**Acceptance:** `grep -riE 'autonom(ous|y)' plugins/codebase-scribe` returns nothing
— excluding `IMPROVEMENT-REPORT.md` until wave 7 deletes it (eval fixtures contain no
matches; that carve-out is unnecessary); 9e case numbering is self-consistent.

## §9. Delivery

- **Branch:** all work on `scribe-improvements` (fork), PR'd to fork main in wave
  order. **The kiali completion run happens after wave 3 at the earliest** (the
  wave-1 Review Gate guard covers the interim regardless).
- **Waves:**
  1. §2 + §1 + the cross-cutting frontmatter rules — the kiali-blocking wave
     (includes the wave-1 guard on the two Review Gate restatement lines).
  2. §5 + §4's gitignore seeding (moved up so §3's snapshots never land untracked).
  3. §3, gated by the two-question Cursor pre-check, including the eval-tree
     relocation (`git mv` + `dataset.path` update; suite stale-but-present until
     wave 6).
  4. §4 remainder (decisions lifecycle, incorporation rules, question-pass contract,
     Step 3 extraction, kiali claims migration).
  5. §6 (strip first, then P2), §7, §8, P4/P5 polish.
  6. **Evals:** regenerate discover/draft/maintain suites against final contracts;
     regenerate the relocated scribe-review suite including `eval.md`. The `skill:`
     key is updated to address the agent — implementation-time verification covers
     the runner's agent-dispatch syntax (suite *discovery* outside `skills/` was
     already verified by the wave-3 pre-check, which gates the relocation itself).
     "Keep runner config" excludes everything encoding the removed P3 strings
     (`recommendation_actionable`, `outputs.schema` lines, `review_quality`'s
     prompt, corresponding `eval.md` text). Keep model ids (`claude-opus-4-6`). Old
     fixture architecture (`.claude/scribe/inventory.yaml`, `AGENT.md`) fully
     removed.
  7. **Cursor audit** (M6) + delete `IMPROVEMENT-REPORT.md` + README "Known
     limitations in Cursor" section.
- **Versioning:** single bump 1.2.6 → **1.3.0**, in all four version-carrying files
  (both plugin.json manifests + the codebase-scribe entries in both root
  marketplace.json files); P4 sync check is a four-way comparison.
- **README (P5):** full re-read at the end; align every behavioral claim
  (fresh-session review, .claims.yml wording, Standard Files list, gitignore
  automation, scan example validity, `questions`/`default_branch` config, Human
  Input caveat, version).
- **Upstreaming to origin** (minus the §6 strip commit): later, separate decision.

## Decisions log (user-ratified 2026-07-27)

1. H7 contract: TL;DR mandatory for mature topics; Links strongly suggested; 5-section
   skeleton for new stubs only.
2. #39 strip: upstream.md content only, revertible isolated commit; redirects and
   README/CONTRIBUTING/ARCHITECTURE handling kept.
3. Provenance: frontmatter `decisions:` list; `.claims.yml` stays gitignored cache.
4. Review agent: no model pin.
5. Question-pass counter: frontmatter `question_passes`, settles at 2.
6. M10: containing-match with exact-match preference.
7. Version: 1.3.0, single bump at the end.
8. Spec committed on the feature branch.

## Revision log

- **rev 4.1 (2026-07-27):** closes the E/F fix-verification findings on rev 4 (all
  their round findings confirmed resolved; residuals were in the rev-4 fixes
  themselves): human-attribution carry-forward keyed on positive evidence (the
  pure absence test would have scored freshly drafted stubs 100% human — inverting
  the no-false-confidence guarantee) and made non-ratcheting (wholesale rewrite
  re-infers the slug); shallow-gate freshness position unified (drafted-this-run
  topics stamp 100 truthfully at any depth; the 9f-only suppression contradicted the
  writer-of-record argument); stub test made fence-aware; 12d's ARCHITECTURE-pointer
  duty scoped to full-management mode; 12b option 1 added to the identity-read
  allowance; 9e condition 2 widened to cover all three 9d escalation routes (in both
  §3 and §8); draft-side reset timing sequenced (after Step 9 on the 9b path, with
  its near-unreachability noted); eval-suite discovery check moved into the wave-3
  pre-check that gates the relocation; row-count wording fixed.
- **rev 4 (2026-07-27):** reworked after voting round 2 (fresh voters E and F, both
  NOT_APPROVED; full union applied). Headline changes: 12f hub template body actually
  written (both voters found "discover's template verbatim" describes a one-sentence
  list, not a template); migration-mode regression guard (the seed-flow change let
  12e rename AGENTS.md before draft consumed `migration_source` — pending topics now
  re-point at the backup); discover overwrite-refusal (name collision would have
  destroyed a mature topic and all protected keys); Step 5 row rewrites given as
  normative table (drifted gains the non-null conjunct; unverified gains the
  counter/questions conjuncts — voters showed the spec asserted outcomes without
  writing the rules); snapshot sentinel disambiguated (zero-byte = new_draft, absent
  = major_rewrite — previously the same state got both labels); watch-path repair
  loops to a fixed point in one run and reports preserved-but-dangling single-segment
  entries; question-pass reset fallback restricted to the two 9f-bypassing paths
  (its broader trigger overrode 9f's deliberate non-reset); decisions ids written at
  §11 where they exist, with §11 skipping decision-reserved ids; human-attribution
  survival across redrafts added to the cross-cutting rule; kiali migration keyed on
  trackedness alone and made per-decision idempotent; dispatch identifier
  (namespaced vs bare) folded into the Cursor pre-check with the code-reviewer bare-
  name precedent recorded; shallow gate extended to maintain §2 and 9f's freshness
  stamp, with the git<2.15 fallback; maintain snapshot scope defined; wave-1 guard on
  the Review Gate restatement lines + kiali-run-after-wave-3 constraint; 9d
  escalation routes mapped to renumbered 9e; 9d replacement text completes the
  sentence pair; detached-HEAD/unresolved-default behavior for non-main-only
  strategies; stub marker anchored; STATUS.md hook carve-out preserved; 12f
  ARCHITECTURE pointer added by 12d when the file appears; marker placement scoped to
  12e; strip list + fixture exclusions completed (second fixture found); eval-suite
  discovery verification added; hook docs_dir extraction fully specified;
  IMPROVEMENT-REPORT.md deletion owned by wave 7; assorted wording precision.
- **rev 3.1 (2026-07-27):** closes C/D fix-verification findings: rework-mode guard
  retained in the M2 reduction; trailing-slash normalization; shallow gate to all SHA
  consumers; question_passes reset fallback; accepted-regression notes.
- **rev 3 (2026-07-27):** full union of voting round 1 (C, D): cross-cutting
  frontmatter preservation; M2 dedup reinstated on corrected evidence; one stub test;
  question-pass fallback + contract; scan shape scoped to non-null; shallow-clone
  gate; branch threading; path-shape repair; migration anchored; snapshot semantics;
  brief contract; eval relocation in-wave; current-row default; session guard;
  re-link uniqueness; 12f introduced; heading renames; branch-local precedence.
- **rev 2.x (2026-07-27):** review round 1 (A, B) rework and its three
  fix-verification rounds — see git history for the detailed log.
