# codebase-scribe Improvements — Design Spec

- **Date:** 2026-07-27 (rev 6 — reworked after voting round 4: fresh voters I and J,
  both NOT_APPROVED; full union applied)
- **Status:** Pending gate decision after voting round 4
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
lands — defined as **after wave 3 at the earliest**. That run directly exercises
scan-SHA validation (§2), the structure contract (§1), the branch gate (§2), and the
watch-path repair (§2). **kiali's default branch is `master`, not `main`** (verified
via the GitHub API, 2026-07-27) — the branch gate is specified against the detected
default branch for exactly this reason.

The plugin is **manually run**. **Cursor support is real** (actively used); §3 carries
a Cursor pre-check because of it.

## Goals

1. The review gate runs in genuinely fresh context, matching what the README claims.
2. User-sourced tribal knowledge — content AND its attribution — survives clones,
   machine switches, and redrafts of the topic that holds it.
3. Drift detection cannot be silently disabled by the plugin's own bookkeeping
   (dangling scan SHAs, narrowed watch paths, off-default-branch generation,
   maintain-pass self-certification) — and already-damaged deployments (kiali) are
   repaired, not just protected going forward.
4. Mature documentation with domain-specific structure is a first-class citizen.
5. One canonical copy of every internal contract (templates, protocols, orchestration).
6. Eval suites describe the architecture that actually ships.

## Non-goals and accepted residuals

- No new features beyond the fixes and the repairs required by them.
- No change to the three-phase design. Two scoring changes are in scope by
  ratification: the `undercooked` classification consequence (§2) and the
  `human_input` computation basis (`human_sections`, cross-cutting rule — user
  decision 2026-07-27).
- No automation/cron support — the autonomous machinery is removed.
- No Cursor feature parity — audit, one targeted pre-check (§3), honest gap docs.
- **Custom `output.docs_dir` becomes genuinely supported** (consistency repair, not a
  feature; `branch-local`'s override is specified in §5).
- **Accepted residuals, recorded:**
  - `branch-commit`: still stamps feature-branch SHAs; a squash merge dangles them;
    the new scan validation makes that self-healing (drifted + freshness 0 + redraft)
    at the cost of a spurious full-drift classification after every squash merge.
  - `branch-local`: `.scribe/branch-docs/` is shared across branches, so the
    reachability test fails after a branch switch and the branch-docs set redrafts —
    same self-healing shape as above.
  - A rebased/force-pushed default branch dangles every stored `scan` at once under
    `main-only`; the whole doc set classifies drifted and redrafts — self-healing,
    same mechanism.
  - `_retired_ids` for **inferred** claims lives only in the gitignored, deletable
    `.claims.yml`; after cache deletion those ids become reusable. Decision ids are
    protected by the frontmatter reservation; inferred-claim id reuse only affects
    cache-internal bookkeeping and is accepted.
  - Dropping Step 5's `<50 words` stub disjunct (it is an alternative in the source
    row, not a conjunct — dropping it *narrows* the stub set) exposes one rare crash state (short
    real body + valid scan → `current`); maintain §7's checks are the advisory
    backstop.

---

## Frontmatter key preservation and human attribution (cross-cutting)

Committed frontmatter keys added by this spec: `decisions`, `question_passes`,
`human_sections` (`review_notes` already exists).

1. **Carry-through rule:** any frontmatter key not explicitly named by a writer is
   carried through unchanged. Draft §10's enumerated write list is amended to add
   "…, and preserved verbatim: `decisions`, `question_passes`, `human_sections`,
   `review_notes`, and any other keys present."
2. **Human attribution is positive evidence, not inference (ratified 2026-07-27):**
   a new committed frontmatter list `human_sections:` holds the top-level section
   slugs credited to human input. It is **written when HARD RULE 4 fires** (a user
   answer is incorporated into a section) and pruned only when the section's heading
   no longer exists in the file (mirroring Step 3's orphan pruning, which is extended
   to prune `human_sections` orphans the same way it prunes `inferred_sections` —
   **and Step 3's prune itself gets a one-line pre-existing-bug fix while it is
   being edited**: it currently checks entries "against actual `##` headings" while
   draft §4 stores subsection entries with `###` headings, so every `###` entry is
   pruned on the first pass; the check is extended to compare `##` and `###`
   headings at their own levels).
   **`human_sections` is a set — adding an already-present slug is a no-op** (the
   incorporation targets are a small fixed set, so repeat credits are the common
   case and must not inflate the score past its meaning).
   **`human_input` is computed from it:** (slugs in `human_sections` whose headings
   exist / total `##` sections) × 100; 0 when the topic has zero sections.
   **Heading↔slug mapping, stated once:** heading existence (for the prune and the
   formula) is tested by applying draft §4's slug algorithm — the canonical
   location — to each **fence-aware** `##` heading and comparing; that same
   fence-aware heading set is the formula's denominator. (Slugs are not
   invertible, so the test always slugifies live headings, never de-slugifies.)
   Consequences, replacing rev 4.1's absence-inference machinery entirely — **every
   site that computes the score or incorporates an answer is rewritten, in wave 1**:
   - Draft §8's zero-rule ("if no user answered any design decision questions
     during this draft, the score is 0") is **deleted outright — the formula is
     universal** and already returns 0 for an empty `human_sections` (so §1's
     "first draft of a stub yields `human_input: 0`" acceptance holds as a
     consequence, not a special case; a retained special case would invite a
     formula-bypassing branch). **Both** §12 checklist items encoding the old basis
     ("higher if sections were removed from `inferred_sections`"; "the top-level
     section slug is removed from `inferred_sections` (HARD RULE #4)") are
     rewritten to the `human_sections` basis.
   - **The Wrap-Up Pass is a fourth answer-incorporation site and is rewritten**:
     it currently says only "Remove answered sections from `inferred_sections`" —
     under the new basis it must also add each answered section's slug to
     `human_sections`, recompute `human_input`, and rewrite the touched topics'
     frontmatter (the pass runs *after* §8/§10 wrote the files, so without the
     recompute the credit would not land until the next run). Draft §6's and §7's
     restatements of the duty ("Per HARD RULE #4, remove the top-level section
     slug…") are rescoped to point at the rewritten HARD RULE 4 rather than
     restating half of it.
   - **Maintain §8's Human Input line is rewritten to the `human_sections` formula**
     (no zero-rule — maintain never solicits answers). Maintain is the steady-state
     recomputation site; left on the old absence formula it would re-manufacture
     credit from Step 3's pruning on every all-current run.
   - **Draft HARD RULE 4 is rewritten** — it is the designated trigger, and its
     current text ("This drives the `human_input` score. Skipping this step means
     the score never changes…") asserts the old basis. New duty: add the section's
     slug to `human_sections` (the scoring list) AND remove it from
     `inferred_sections` (for that list's other consumers); the stale rationale
     sentences are replaced.
   - Redrafts cannot zero the score (the list carries through per rule 1) and
     cannot inflate it (attribution is never inferred from `inferred_sections`
     absence — Step 3's pruning of renamed headings no longer manufactures credit).
   - **Draft Safety Rule 2 is amended in the same wave** — its current wording
     ("only add to or update **inferred** sections") permits rewriting a
     human-credited section's body, because every generated section is also in
     `inferred_sections`; under §1's rewrite-bodies-in-place instruction that
     would silently drop the user's prose while `human_sections` still claims
     credit. New clause: "sections listed in `human_sections` may be extended,
     but their existing prose must be preserved verbatim" — also added to §1's
     positive redraft instruction.
   - No "extended vs replaced" test is needed: attribution persists while the
     heading exists; the answer *text* is protected by the amended Safety Rule 2. A
     heavily rewritten section retains credit as long as the heading and the
     incorporated answer survive — accepted, and honest, since the answer is still
     present. **Accepted residual:** a *manual* heading rename (`## Gotchas` →
     `## Pitfalls`) prunes the credit even though the answer survives — draft-side
     redrafts are safe (the §1 positive instruction preserves the heading set), but
     Goal 2's "survives redrafts" does not extend to hand renames.
   - `inferred_sections` keeps its existing role (tracking machine-generated
     sections for other purposes) but no longer drives `human_input`.
3. **Discover never overwrites:** discover refuses to write a topic file that
   already exists. **Collision handling, specified:** discover creates the remaining
   topics and returns the colliding names; the orchestrator drops colliding names
   from the working batch (including a focus-mode Step 6d batch), does not
   re-attempt creation, and surfaces them in the Step 13 summary with a rename
   suggestion.

**Acceptance:** redraft a mature topic carrying `decisions:`, `question_passes`, and
one `human_sections` slug — all survive and `human_input` is unchanged; the first
draft of a stub yields `human_input: 0` when no questions were answered; renaming a
section heading prunes both lists' orphans without transferring credit; a discover
collision drops only the colliding topics and reports them.

## §1. Structure contract (two-tier) — findings H7, M1

### Contract

- **Stub topics**: body empty or contains a line beginning with the stub placeholder
  marker (`*Stub — will be populated`), **ignoring lines inside fenced code blocks**.
  The full 5-section skeleton **plus TL;DR blockquote** is required at creation.
- **Mature topics**: anything not a stub. TL;DR blockquote mandatory, positionally:
  after the closing `---` of YAML frontmatter, the first non-blank line following the
  first `# ` heading line must begin with `>`; **heading detection is fence-aware**
  (a fenced `# ` line is not a heading); a file with no `# ` heading is flagged as
  missing its TL;DR (both tiers). `## Links` strongly suggested, not required.
  Free-form domain headings fully legitimate.
- **One stub test everywhere:** Step 5's `stub` row is rewritten to "body is empty or
  contains the anchored, fence-aware stub marker, or has `migration_source`" — the
  `<50 words` disjunct dropped (an alternative in the source row — dropping it narrows the stub set; accepted residual above). `migration_source` is a
  Step-5-only routing signal, intentionally absent from the maturity test.
- **Fence-awareness algorithm (hook):** specified at the same level as the docs_dir
  extraction — an `awk` pass toggling a state flag on lines matching `` ^``` `` or
  `^~~~`; marker and heading matches count only while the flag is off.

### Enforcement split

| Layer | Enforces |
|---|---|
| Hook (`doc-validate.sh`) | Mature topics: TL;DR presence (positional, fence-aware). Stub topics: the 5-section skeleton **and TL;DR presence**. The existing `*/STATUS.md` exclusion survives. Silent about Links. |
| Maintain quality checks (§7) | Flags missing TL;DR; **advisory note for a missing `## Links` section** (this advisory lives in maintain only — the review agent's `MISSING_XREF` tag covers missing cross-topic *references*, not section presence, and is unchanged). §7's 5-heading check rewritten to the two-tier contract. |
| Review agent | No change to its tag set. |
| Draft | Always writes TL;DR and a Links section in content it generates. Four sites rewritten to the two-tier contract: §3's structure rule, the Content standards "MUST have all 5 sections" rule, the §12 checklist, Rework step 8. **Positive redraft instruction (the §3 rewrite is a template change, not just a check change):** for a non-stub topic, draft preserves the existing top-level heading set and rewrites section bodies in place, adding a TL;DR and a `## Links` section only if absent; the 5-section skeleton applies to stub drafts only. |

### Hook fixes (same file)

- Matcher `Write|Edit` → `Write|Edit|MultiEdit` (verify `MultiEdit` existence at
  implementation; harmless if folded into Edit).
- TL;DR check per the Contract; fence-aware per the algorithm above.
- docs_dir awareness: resolve `.scribe.yml` from `$CLAUDE_PROJECT_DIR`, fall back to
  cwd; match an indented `docs_dir:` line inside the `output:` block, strip quotes
  and trailing comments; default `docs/agents` on any failure; a leading-`/` value is
  an exact path prefix; accept absolute and repo-relative `file_path`. Documented
  gaps: the `branch-local` override is invisible to the hook; `$CLAUDE_PROJECT_DIR`
  in Cursor unverified until wave 7 (degrades to cwd, then default — today's
  behavior).
- jq precedence: prefer jq; else grep/sed extraction; else exit 0 silently.
- Warning text becomes advisory.

**Acceptance:** a mature topic with domain headings and a TL;DR passes hook +
maintain cleanly; missing TL;DR (or no `# ` heading) is flagged on either tier; a
stub missing a skeleton section or TL;DR is flagged; STATUS.md never flagged; custom
docs_dir validated for absolute and relative paths; no stderr without jq; no site in
draft or maintain requires all five headings of a non-stub topic; Step 5's stub row
has no word-count test; a mature topic quoting or fencing the marker is not a stub.

## §2. Drift integrity — findings H6, H3, M7

### Default-branch detection

Fail-closed ladder, detected once per run by the orchestrator:

1. `.scribe.yml` `default_branch` (flat key; in the Error Handling defaults list —
   default: auto-detect — and the README config block).
2. `git symbolic-ref refs/remotes/origin/HEAD`.
3. `git rev-parse --verify origin/main`, then `origin/master`.
4. Remote exists but unresolved: under `main-only`, **refuse** and tell the user to
   set `default_branch`; under other strategies, pass null (guards inert).
5. **No remote at all: probe local `refs/heads/main`, then `refs/heads/master`, and
   use it if found; only when neither exists fall back to the current branch.** (A
   local-only repo with `main` and `feature/x` must not have the gate compare
   `feature/x` to itself — that was the exact hole the ladder exists to close.)
6. **Git unavailable entirely** (not a repo, or no git binary): under `main-only`,
   refuse; otherwise pass null. Error Handling #4 is noted as edited — its
   "warn and continue" no longer applies to the `main-only` gate (the preamble's
   refusal exception covers it).

**Threading:** the orchestrator passes `default_branch`, `branching_strategy`,
`current_branch`, **and the repaired `watch_paths` (below)** in every skill brief;
skills never re-detect. Detached HEAD: `main-only` refuses; `branch-local` proceeds
with `current_branch` = HEAD SHA; `branch-commit` refuses.

**Error Handling updates:** preamble gains "…except where an entry below explicitly
refuses the run"; entry #5 rewritten per the strategy split; **entry #6 is rewritten
to "No remote OR unresolvable default branch"** — covering both the ladder's
no-remote rung AND rung 4's refusal (remote present, nothing resolves), so a
refused user finds a documented cause; **entry #4 is noted as edited** (the
git-unavailable rung); a new entry covers scan validation and its shallow-clone
interaction with #4. **Recorded user-visible change:** in a non-git directory
under the default `main-only` strategy the run now refuses rather than degrading —
the plugin's documented scope is git repositories, and its entire drift model
needs one.

### Scan-SHA validation (H6)

Every **non-null** `scan` validated at Step 3; `scan: null` is never a validation
failure (routed by the Step 5 rows).

- **Shallow-clone gate first, covering every stored-SHA consumer AND maintain's
  git-history features:** if `git rev-parse --is-shallow-repository` is true
  (fallback: `test -f .git/shallow`), skip scan validation, Step 5's classification
  diff, maintain §1, **§2 (no input without §1's churn), §3's rename resolution via
  `git log --diff-filter=R` (and therefore §9's escalation — broken references are
  reported, never flagged as deletions, since renames are indistinguishable from
  deletions in a shallow clone)**, §4, §5, §8, and the Step 4 session-SHA check;
  warn once. Topics classify from body and frontmatter alone; no frontmatter is
  degraded; freshness holds its last value — except topics actually drafted this
  run, which stamp `freshness: 100` truthfully at any clone depth.
- **Shape:** `^[0-9a-f]{7,40}$` (the README's example `"a1b2c3d4"` stays
  shape-valid — it would still fail resolution in a real repo, which P5's README
  alignment notes).
- **Resolution and reachability:** `git cat-file -e <sha>` AND
  `git merge-base --is-ancestor <sha> HEAD`.

On failure: the topic **never classifies `current`** — it classifies `drifted`
unless a higher-priority row (`stub`, `escalated`) matches, both of which also route
to a redraft — and its frontmatter `freshness` is set to 0 at Step 3, before any
STATUS.md regeneration. Four STATUS.md writers (draft's regeneration, maintain §10,
command Step 10, 9f item 6) source their scores from frontmatter; discover writes
constant 0% for the stubs it creates and never consumes degraded values.

**Step 5 row rewrites (normative; five rows change — `stub` owned by §1,
`unverified` owned by §4):**

| Row | New criterion |
|---|---|
| `stub` | body empty or anchored fence-aware stub marker, or has `migration_source` |
| `drifted` | `scan` is non-null AND (watch_paths changed since scan SHA OR scan validation failed). The header diff is skipped for null-scan topics. |
| `undercooked` | `scan` is null AND body is not a stub |
| `decision_drift` | has a `decision_drift` stale flag — **the "and topic is otherwise current" conjunct is deleted** (it becomes circular once `current` means "no other row matched"; the priority column already expresses precedence) |
| `unverified` | `human_input == 0` AND `freshness >= 40` AND `question_passes < 2` AND `questions` is not `false`. **An absent `question_passes` is treated as 0**; an absent `questions` is treated as true — both defaults stated here because this row ships in wave 1 while the keys arrive in waves 4/5 (graceful-degradation dependency, noted). |
| `current` | no other row matched |

Escalation stays maintain §9 (`escalated` flag + `completeness: 0`; its parenthetical
is rewritten to name `escalated`).

**Other stored-SHA consumers (full clones):** on an unresolvable/unreachable SHA,
maintain §1 reports full churn **without running its diff** (feeding §2's drift
table its input), and §4/§5/§8 skip their diff-derived branches; Step 4 discards a
session whose `last_active_sha` fails the same test; **`resolved_at` on a
`decisions:` entry is the fourth guarded consumer** (handling specified at its
point of use in §4: ignored when unresolvable, diff falls back to `scan`);
`_meta.<topic>_extracted_at` needs no guard (equality-only; mismatch →
re-extract, the safe direction).

### Freshness/scan self-certification closed (Goal 3, fourth mechanism)

**9f stamps `freshness: 100` and advances `scan` only for topics whose content was
drafted or reworked in this run** — a §4 question pass is explicitly neither, so 9f
neither stamps freshness nor advances scan for it. **The same exclusion is written
into draft §8 and §10 themselves** (their "always `100`" / "scan SHA = current
HEAD" instructions are unconditional today; §2 names them as edit sites for the
branch gate, and they are edit sites for the question-pass exclusion too — a
question pass runs *through* draft, and an unguarded §10 would stamp `scan: HEAD`
on an answered question and erase accumulated drift). After a maintain-only pass,
9f preserves the freshness maintain §8 computed and does NOT advance `scan`; maintain §8's own
"Update `scan` SHA to current HEAD if changes were made" is deleted — mechanical
reference fixes are repairs, not content updates, and advancing `scan` for them
would make real drift permanently invisible (400 commits of churn erased by one
renamed-path fix).

### watch_paths: directories forever, plus a one-time repair (H3)

- Draft's §9 is deleted. **The heading itself is removed and the numbering simply
  skips from 8 to 10** (no empty heading remains — an empty heading is a live
  instruction surface); draft sections 10–13 keep their current numbers, and every
  cross-reference in this spec and inside the skill uses current numbering.
- **Repair, by path shape:** at Step 3, per entry: normalize trailing slashes; then
  iteratively — until the entry resolves to an existing directory or is reduced to a
  single segment — replace it by its parent; dedupe. Single-segment entries are
  preserved as-is; **preserved single-segment entries that resolve to neither an
  existing directory nor an existing file are reported in the Step 13 summary**
  (permanently drift-blind scopes must not be silent). Purely mechanical — origin is
  not distinguishable and not consulted. **Accepted consequence, recorded:** a
  legitimately file-scoped multi-segment entry (`cmd/server/main.go`) is widened to
  its directory permanently — precise file scopes below the top level do not
  survive the directories-forever rule.
- **Persistence (the repair must land):** the repaired list is **written back to the
  topic's frontmatter at Step 3, before snapshots are taken** (so the change is not
  classified by Step 9), and the repaired value is threaded in the skill brief;
  draft §10 restamps `watch_paths` from the brief's repaired value. Without a named
  writer the repair would be re-derived and discarded every run.

### Branch gate (M7)

Both layers conditional on `main-only`:

1. Step 0's check (already an exit; wording hardening) refuses against the detected
   default branch.
2. Every stamping site refuses to update `freshness` and `scan` off the default
   branch: command 9f; draft §8/§10; draft Rework step 6; maintain §8; and — for
   the wave-1 window before §3 deletes it — **draft's Review Gate item 6** ("…
   update scan SHA …"), the only Review Gate line that restates the stamp
   (maintain §12's item 4 names 9f without restating it and needs no guard).
   Skills read branch state from the brief — **the three enumerated brief blocks
   are named edit sites: draft's Inputs, draft's Rework Brief Contents (rework
   reaches a gated stamping site and receives only the enumerated brief), and
   maintain's Inputs.**

**Acceptance:** dangling/unreachable/`"HEAD"` scans classify `drifted` (or a
higher-priority redraft row) with `freshness: 0` persisted; a shallow clone skips
validation and all git-history branches with one warning, degrades nothing, and
**stamps `freshness: 100` only for topics drafted in that run**; `scan: null` + real
body → `undercooked`; a dangling `last_active_sha` discards the session; the repair
converges in one run, persists to frontmatter, reports dangling single-segment
entries, and survives a draft restamp; a maintain-only pass leaves `scan` untouched
and freshness at maintain §8's computed value; committing a new file into a watched
directory classifies drifted next run; `main-only` off-branch refuses at Step 0 and
at every stamping site; `branch-local` finalizes normally; a fully-drafted topic
with completeness 20 **and `human_input > 0` or `question_passes: 2`** classifies
`current` (a just-drafted topic with no answers and no passes legitimately
classifies `unverified` — that is the question loop working, not a defect).

## §3. Review pipeline — findings H1, M2, M4, P3

### scribe-review becomes a plugin agent (H1)

- New `agents/scribe-review.md`: frontmatter `name`, `description`, `color`,
  `tools: Read, Bash, Grep, Glob` — and **deliberately no `model` key**, a
  divergence from `docs/contributing.md`'s documented agent shape (`name,
  description, model, color, tools` — a PR checklist item, which the sole in-repo
  precedent satisfies with `model: sonnet`). Ratified: the plugin ships to
  environments with different model availability. **The exception is recorded
  where the convention lives**: one clause added to `docs/contributing.md`'s
  checklist item — "`model` optional for plugins shipping to multiple hosts" —
  in addition to the rationale in the plugin README's Documentation Review
  section.
  System prompt = the merged `skills/scribe-review/SKILL.md` +
  `skills/prompts/review-adversarial.md`, preserving both divergence directions
  (Scoped Re-Review + REWORK_NEEDED fail-safe; Common LLM Errors + changelog rule).
- **Eval design — no relocation (replaces earlier revisions' `evals/` move):** the
  repo's convention docs (`README.md` eval requirements, `docs/contributing.md`
  layout) mandate `skills/<name>/eval.yaml`, and `/eval-analyze` reads a SKILL.md
  as its input. The in-repo `code-reviewer` plugin ships an **agent + full skill
  pair** (`agents/adversarial-reviewer.md` alongside a 106-line
  `skills/adversarial-review/SKILL.md` that duplicates the protocol — precedent for
  keeping the skill *path*, NOT for a thin pointer; the duplication is exactly what
  Goal 5 eliminates). Design: `skills/scribe-review/` is kept, its SKILL.md reduced
  to a **dispatching stub** with one operative instruction — "This skill is
  superseded by the `scribe-review` agent, which holds the review protocol.
  When invoked (including by the eval runner), construct the Step 9c brief from
  the provided inputs, dispatch the `scribe-review` agent via the Agent tool, and
  return its report verbatim." — so an eval run produces the full report the
  judges score, evaluating the agent indirectly through the dispatch.
  `skills/prompts/review-adversarial.md` is still deleted (merged into the agent).
  Consequences: no relocation, no eval-layout convention edits (the agent-`model`
  checklist clause in `docs/contributing.md` is a separate, recorded edit),
  `/eval-analyze` keeps a SKILL.md input (the stub, whose eval semantics are
  "dispatch and relay").
  **Fallback** (pre-check question 3): if the eval runner's environment cannot
  dispatch the agent through the stub and surface its report in the captured
  conversation, the skill instead carries a protocol copy **mechanically derived
  from `agents/scribe-review.md`** — with a generation header naming the source
  file, and the copy added to P4's sync check (alongside the four-way version
  check) so drift is caught mechanically; regenerated whenever the agent changes.
  Generated duplication with a single canonical source — mirroring code-reviewer's
  shape without its hand-maintained divergence.
- **Brief contract:** brief passed as the Agent tool's **prompt** (no `args`
  parameter exists; 9c/9d item 3 phrasing rewritten); 9c's `source_files` becomes
  paths-only (500-line excerpt clause dropped); the merged agent's Inputs section
  rewritten to match.
- **Dispatch identifier — verified, not assumed:** the repo's only working precedent
  dispatches plugin agents by bare name (`adversarial-reviewer`). The Cursor
  pre-check verifies the exact `subagent_type` string in both hosts; the spec's
  `codebase-scribe:scribe-review` is replaced by the bare form if that is what
  resolves.
- **Dispatch sites:** (1) command 9c — including its trailing sentence naming the
  two protocol files, rewritten as part of the site; (2) command 9d item 3.
  **Sites 1–2 each become this quoted sentence:** "Dispatch the `scribe-review`
  agent via the Agent tool (`subagent_type`: the identifier verified by the
  pre-check — bare `scribe-review` per the code-reviewer precedent, unless
  verification shows otherwise), passing the brief below as the agent's prompt —
  do NOT hand-write a review prompt for a generic agent, and do NOT use the Skill
  tool for review." Sites (3) draft's Review Gate and (4) maintain §12 inherit the
  dispatch rule via their reduced pointer text (below). **The 9c brief gains a
  `docs_dir` field**, and the merged agent's Inputs section documents it — the
  protocol's cross-topic check hardcodes `docs/agents/` today while the agent is
  forbidden from reading `.scribe.yml`, so without the field a custom-docs_dir
  repo silently loses every `MISSING_XREF` finding. Step 8's sub-skill rule is preserved in substance
  with a scope clause, **keeping its rationale sentence**: "Always use the `Skill`
  tool to invoke the draft and maintain sub-skills — do NOT spawn a general-purpose
  `Agent` with a hand-written prompt that replicates a skill's behavior. The `Skill`
  tool loads and executes the actual skill file, ensuring all its rules are followed
  exactly. (Review dispatch is the exception: it uses the dedicated scribe-review
  agent — see Step 9c.)" Step 9's preamble second sentence becomes "The skills
  invoke Step 9 as a whole via their Review Gate pointers."
- **M2 reduction:** draft's Review Gate reduced to: "Skip this section when in
  rework mode — the orchestrator handles scoped re-review via Step 9d. Otherwise,
  **after all topics in this batch are drafted, STATUS.md regenerated, and
  Standard Files processed** [the current leading precondition, preserved]: follow
  Step 9 (Review Orchestration) in `commands/codebase-scribe.md` for every
  topic modified in this pass — dispatching reviews via the scribe-review agent as
  Step 9c specifies — and return to the orchestrator only after it completes for
  all of them." Maintain §12's version omits the rework sentence, keeps its own
  leading precondition ("after all maintenance checks, STATUS.md regeneration, and
  Standard Files Maintenance"), and **appends "…and only then print the §13
  summary"**. Substeps 9a–9f then exist only in the command.
- **Recommendation lines (P3):** "Run `/codebase-scribe` again — targeted correction
  of sections: <list>." / "… — full redraft recommended." The PASS line ("No action
  needed — the documentation is up to date.") is unchanged. The guidance paragraph
  stays but is **restated in the new vocabulary** ("choose targeted correction
  when the structure is sound…; choose full redraft when…") — as written it
  instructs the reviewer to choose between `scribe-maintain` and `scribe-draft`,
  names that no longer appear in the output.
- **9e widening lives in §8 only** (it is a renumbering-dependent edit; §3 merely
  references it — an earlier revision duplicated the text here, which would have
  mis-applied it if wave 3 landed before wave 5).

### Cursor pre-check (gate for the prompts-file deletion and dispatch cutover)

Verify: (1) in both Claude Code and Cursor, plugin-defined agents are dispatchable;
(2) the exact `subagent_type` identifier; (3) **an in-wave verification, not a pre-gate** (it needs the stub and agent to
exist): under the eval runner, invoking the dispatching-stub skill surfaces the
agent's report in the captured conversation (the judges score
`{{ conversation }}` expecting a full review report). **Because today's fixtures
supply no Step 9c brief until wave 6 regenerates them, the wave-3 verification
uses one throwaway hand-authored fixture that does supply a brief** — a small
topic + claims pair sufficient to exercise the dispatch path; it is discarded
after the check. If (1) or (2) fails in Cursor, stop and surface the decision;
if (3) fails, its branch is the non-destructive derived-copy fallback above.

### Snapshots to disk (M4)

- **Deletion at Phase 0 Step 1** (on every run path — seed and uncovered-module
  routes never reach Step 8, so a Step-8-owned deletion would leave stale files on
  disk after those runs, even if never read); **writing at Step 8**: draft
  invocations snapshot the batch; maintain invocations snapshot every topic in the
  docs dir. Per topic: `<topic>.md` (full file), `<topic>.claims.yml`,
  `<topic>.headings.txt` under `.scribe/snapshots/`.
- 9a item 1 reads the pre-skill `scan` from the snapshot's frontmatter. A zero-byte
  snapshot (written when the topic file did not exist at Step 8 — a rare path, since
  discover creates stubs before Step 8; kept as an edge-case guard, not load-bearing)
  is an additional `new_draft` trigger. An **absent** snapshot for a modified topic
  classifies `major_rewrite` (fail toward review).
- 9a diffs the on-disk snapshot against the current file.
- Step 8 verifies/creates the `.scribe/` gitignore entry before writing
  (belt-and-braces with §4's seeding).

**Acceptance:** the review protocol text has one canonical copy, in the agent (the
derived-copy fallback, if taken, is generated from it and sync-checked, not a
second source);
`skills/scribe-review/SKILL.md` is the dispatching stub that relays the agent's
report verbatim (or the generation-headed derived copy, if pre-check question 3
failed) and `skills/prompts/` is gone;
dispatch sites 1–2 use the Agent tool with the verified identifier and sites 3–4
point at Step 9; substeps 9a–9f exist only in the command; rework never recurses;
the first draft of a discover-created stub classifies `new_draft`; a modified topic
with an absent snapshot classifies `major_rewrite`; no snapshot from a previous run
is ever read by 9a (deletion runs at Step 1 on every path); recommendation lines
name only `/codebase-scribe`.

## §4. Knowledge persistence — findings H2, M9, M3

### Provenance in frontmatter (H2)

`decisions:` schema as ratified (id, type, claim, context, recorded, source,
status: active|retired, plus optional `resolved_at` — see the decision-drift
re-flag fix below).

- Preservation: cross-cutting rule 1. Attribution: `human_sections`
  (cross-cutting rule 2).
- **Write timing:** draft §6/§7 record the answer; the `decisions:` entry (with id)
  is written at §11 immediately after the corresponding claim is extracted and
  assigned its id. **Sequential id assignment — in draft §11 AND maintain §6's
  re-extraction — skips ids named in frontmatter `decisions:` (active and retired)
  and in `_retired_ids`** (maintain performs the same assignment and was previously
  unguarded: a reworded decision claim could orphan its id, maintain could hand it
  to a new claim, and a later re-link would duplicate it).
- **Answer incorporation target:** `Dependencies & Context` or `Gotchas`; if neither
  exists, the last `##` section; if no `##` section exists, create
  `## Dependencies & Context`. On incorporation, add the section's slug to
  `human_sections` (HARD RULE 4's `inferred_sections` removal stays for its other
  consumers, but scoring comes from `human_sections`).
- **Re-linking (maintain §6), by content:** match on `{type, topic, first-50-chars}`
  against `active` entries; restore provenance; claim takes the entry's id.
  Uniqueness: many-to-one → first in **`.claims.yml` document order** binds;
  one-to-many → binds none, reported. Residual accepted: reworded claims drop the
  link fail-safe; maintain reports unmatched active decisions.
- **Retirement is a tombstone** (`status: retired`); skipped by re-linking and
  decision drift. All three Decision Drift Resolution outcomes write frontmatter
  first.
- `.claims.yml` stays gitignored; README updated to "regenerable".
- **kiali migration — owner: Phase 0 Step 1, after gitignore seeding (both in
  wave 1); per-decision idempotent. Trigger split in two:** the frontmatter
  *reconstruction* triggers on the cache file being present with `origin: user`
  claims — tracked or not, so an untracked-but-present cache still migrates its
  provenance; only the *untrack* step is additionally gated on trackedness
  (`git ls-files --error-unmatch`). Evidence status: kiali's `.claims.yml`
  trackedness comes from the kiali deployment analysis
  (`kiali/documentation-report.md`) — the same field-data basis as the P7 footer
  strings, re-verified at implementation time like them; the split trigger makes
  the migration correct either way.
  **Selection and mapping, explicit:** claims with `provenance.origin: user` only;
  `id`←claim.id, `type`←claim.type, `claim`←claim.claim,
  `context`←provenance.context, `recorded`←provenance.recorded,
  `source`←claim.source, `status: active`; and the target section's slug is added
  to `human_sections` **only when exactly one `##` section's body contains the
  claim text** (no match or multiple matches → the decision is recorded without a
  section credit — a deterministic rule, since this one-shot migration sets a
  scored committed field on the only real deployment). The frontmatter
  reconstruction proceeds unconditionally; **the `git rm --cached` is gated behind
  an AskUserQuestion** (the plugin is otherwise purely a file-writer, the trigger
  fires in any repo with a committed cache, and an unannounced staged deletion
  could ride into a user's unrelated commit — the trigger is self-disarming once
  untracked, so a declined prompt simply re-asks on a later run). The staged
  untrack and any `.gitignore` modification are reported in the Step 13 summary
  with an instruction to commit.

### Orchestrator-owned .gitignore seeding (M9)

Phase 0 Step 1; idempotent; `.scribe/` + `<docs_dir>/.claims.yml`; skip the claims
entry when the resolved docs_dir is already under an ignored path.

### Question-pass for unverified topics (M3)

- **Selection:** Step 8's `unverified` row invokes draft with `question_pass: true`
  (batched). Step 5 row criterion in §2's table (absent counter ⇒ 0).
- **Pipeline:** ask the §6 question; on an answer: incorporate per the target rule,
  update `human_sections` (and `inferred_sections` per HARD RULE 4), recompute
  `human_input`, extract the claim + write the `decisions:` entry at §11 timing;
  **increment `question_passes` on every M3 pass over the topic — answered,
  skipped, OR when §6's zero-question rule fires and nothing is asked** (otherwise
  a conventional topic where §6 never finds a question would classify `unverified`
  and invoke a no-op pass forever). Output flows through Step 9 (typically
  `claim_change`). A stub's *first draft* asking the §6 question does NOT
  increment the counter — it tracks M3 passes only — so the user-visible ask
  count for a never-answering user is up to three (one at draft, two passes);
  stated so the cap's arithmetic is not misread as two total.
- **NOT done:** reading source files; regenerating existing sections; §5/§7
  questions; the Standard Files block; **HARD RULE 2's 15–20-claim extraction does
  not apply (single-claim extraction only) — HARD RULE 1's batch-completion duty
  DOES apply** (the pass is batched; disapplying the rule would let it ask about
  one topic and strand the rest of the batch as perpetually `unverified`);
  **the pass does not stamp `freshness` or `scan`, and 9f does not stamp them for
  it either — a question pass is neither a draft nor a rework under §2's stamping
  rule** (an appended answer must not advance `scan` and erase accumulated drift;
  §2's rule carries the matching explicit exclusion, enforced at draft §8/§10
  themselves per §2).
- **Settling:** stops classifying `unverified` at 2. **Reset rule, both conditions
  required:** 9f resets only when (a) the topic was drafted or reworked this run
  (§2's stamping predicate — question-pass output classifying `major_rewrite` by
  9a's line-count test does NOT qualify) AND (b) it is not the case that
  `question_passes == 2` with `human_input == 0` — a user who declined twice
  stays settled even across genuine redrafts (that is the acceptance's
  "consistently-skipping user on churny topics" case; without (b), every churny
  redraft would classify `major_rewrite`, reset the counter, and re-open two more
  passes indefinitely). The draft-side fallback is restricted to the two
  9f-bypassing paths (`review.enabled: false` at finalization; 9b-skip evaluated
  after Step 9 returns — near-unreachable under default `auto_trigger`, noted)
  and carries the same condition (b).
- **`questions: false`:** M3 route suppressed; row conjunct classifies such topics
  `current`.
- **Decision-drift re-flag fix (companion to §2's scan freeze):** with maintain no
  longer advancing `scan`, a decision-drift flag the user resolves *without* a
  subsequent draft (Step 8 row 5's "resolve flags first, then draft if needed"
  path) would be re-detected every maintain pass — §4's detection diffs
  `<scan>..HEAD`. Fix: resolution writes `resolved_at: <current HEAD>` on the
  frontmatter decision entry (an optional field added to the `decisions:` schema),
  and maintain §4 diffs from **`resolved_at` when it is a descendant of `scan`
  (`git merge-base --is-ancestor`), else `scan`** — "max" over SHAs is an ancestry
  test, not a comparison. `resolved_at` is a stored SHA and joins §2's guarded
  consumer list: if it fails §2's resolution/reachability test, ignore it and diff
  from `scan` (fail toward re-detection, never away from it).

### Orchestrator visibility

Step 3's extraction list adds: `decisions`, `question_passes`, `human_sections`
(absent `question_passes` ⇒ 0, restated here).

**Acceptance:** delete `.claims.yml`, run maintain → decision drift works,
provenance re-links by content with both uniqueness guards and no id duplication
(maintain-side reservation), retired stays retired; an answer on a TL;DR-only topic
creates the section, credits it in `human_sections`, and raises `human_input`; the
kiali migration triggers on trackedness, maps only `origin: user` claims with the
stated field mapping, resumes after interruption, and reports its repo
modifications; settling holds for a consistently-skipping user on churny topics;
Step 3 extracts the three new fields.

## §5. Discover and hub management — findings H5, M10, P7

- **Discover creates stubs + STATUS.md only**, in the brief's docs_dir; refuses
  overwrites (cross-cutting rule 3). Hub paragraph and AGENTS.md instructions
  deleted.
- **AGENTS.md creation collapses to command Step 12** via **`#### 12f: Hub
  template`**, newly authored (no template exists to copy — discover's line 75 is a
  one-sentence list; Step 1's three-item orphan generator is deleted):

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

  Unknown cells: "see build files". The ARCHITECTURE.md pointer line (under
  Architecture at a Glance) is included when the file exists at write time, and 12d
  adds it later **in full-management mode only**, under that heading if present.
  Call sites: 12b option 1, 12c "Does not exist", 12e option 1. **Identity-read
  allowance — all three call sites where Step 2 never ran:** 12c (orphan mode), 12b
  option 1, **and 12e option 1 (normal mode, unmarked AGENTS.md, user picks
  Replace)** read the repo README and root build file first (12e option 1 may also
  read the backup it just created); bounded to those reads.
- **Orphan-mode draft input:** with Step 1's generator gone, AGENTS.md does not
  exist while draft's Standard Files block runs in an orphan-mode session — that
  block's README/ARCHITECTURE generators fall back to the repo README for project
  identity (AGENTS.md arrives later, at Step 12).
- **Migration-mode ordering:** when 12e option 1 creates a backup, it rewrites every
  topic frontmatter whose unconsumed `migration_source` names the renamed file to
  the backup filename — **and draft's migration flag message uses the
  `migration_source` value rather than the literal `AGENTS.md.bak`** (the backup may
  be `.bak.N`).
- **Seed-run flow:** after 2d, continue to Steps 10–13 — **on both entry paths
  into Step 2** (first-run seed/migration AND Step 8 row 7's uncovered-modules
  route, which re-enters the same flow); 2d's message deleted; Step 13's line is
  the single "run again" message either way.
- **Documentation-heading match (M10):** exact `## Documentation` preferred, else
  first `##` heading containing "Documentation" (case-insensitive), else create.
  Applies to 12d (both variants + create-if-missing) and 12e option 2; the marker
  placement sentence applies to 12e option 2 only. Residual (multi-heading hubs)
  accepted.
- **Stale-content refresh (P7):** exact-match removal of the two field-observed
  footer variants ("…these stubs" / "…the stubs", with/without backticks), only when
  no stubs remain; strings verified against the kiali hub at implementation time;
  the acceptance criterion is conditional on that verification. **Owner: 12d,
  full-management variant only** — append-only mode is confined to the
  Documentation section and cannot reach a footer below it; append-only hubs keep
  the footer (documented gap).
- **docs_dir threading:** hardcoded `docs/agents` in behavioral instructions →
  "the configured docs_dir (default `docs/agents`)": command Steps 3, 10, 9f item
  6, the preamble; draft's claims path, STATUS.md, README-generation links, **the
  ARCHITECTURE.md generation template's topic links, and the CLAUDE.md/GEMINI.md
  redirect bodies** (content-generating sites — under a custom docs_dir they emit
  dangling links into generated files); maintain's claims path, STATUS.md,
  standard-files checks; **discover's HARD RULE 2, stub path, and STATUS.md
  path**. (Step 12's link matching already generic.) Resolved once in Phase 0,
  threaded in briefs — and in the 9c review brief (§3). `branch-local` override
  wins; Step 3's mismatch warning suppressed under it.

**Acceptance:** custom docs_dir works end-to-end with no mismatch warning
(enumeration illustrative, catch-all authoritative); a fresh seed run leaves a
12f-instantiated AGENTS.md **unless `agents_md_policy` is `none`, or `manual` —
which prompts via 12b** — and prints exactly one "run again" message; a
migration-mode Replace re-points pending `migration_source` and draft's flag
message names the actual backup; orphan-mode standard files use README identity;
grep finds no "discover skill's hub template" reference; `## Architecture
Documentation` hubs append correctly in both 12d and 12e paths; field-verified
legacy footers are removed; a seed-time hub gains the ARCHITECTURE pointer once the
file exists (full-management mode).

## §6. Standard Files and the #39 strip — finding D5

- **Strip list (complete):** draft Step A's upstream-detection block; its
  `docs/upstream.md` classification rules; Step A's file-enumeration entry for
  `docs/upstream.md` (incl. the "or `docs/`" parenthetical); Step B's upstream
  question text and prompt-order entry; Step C's `docs/upstream.md` template (incl.
  its rules block); the ARCHITECTURE.md upstream link rule; command Step 13's
  `docs/upstream.md` mention.
- One isolated revertible commit, landing **before** P2 (revert note in the commit
  message: a future revert re-adds upstream as a multiSelect option).
- **Eval fixtures permanently excluded from the upstream grep** (`skills/**/eval/`;
  known legitimate matches: case-004's reverse-proxy content and scribe-review
  case-001's "upstream API gateway" line).
- **Keep:** README/CONTRIBUTING/ARCHITECTURE handling; CLAUDE.md/GEMINI.md
  redirects.
- **P2 batching, shape specified:** one multiSelect AskUserQuestion listing each
  missing/thin standard file as an option, with the per-file classification text
  ("thin, ~N lines" / "missing") carried into that option's description; a second
  call only when more files qualify than fit one question's options (the exact
  per-question option limit is verified against the host tool schema at
  implementation time, not asserted here). **Step B's "one at a time, sequentially (do not batch)" clause is
  deleted by the P2 commit; draft §7's identically-worded focus-mode HARD RULE is
  NOT touched.**

**Acceptance:** no upstream.md/upstream-detection mention in command, skills, hooks,
or README (fixtures excluded); the strip commit touches only upstream content and
predates P2; at most 2 Standard Files questions; §7's sequential HARD RULE intact.

## §7. Content standards — findings M8, P1, P6

- Citations: `symbol in file`, never bare line numbers (kiali natural experiment).
- Volatile inventories: describe where they live; never enumerate unless review
  mechanically re-verifies each run.
- Claims (P1): "up to 15–20, proportional — do not pad small topics."
- Questioning (P6): §6 may ask zero questions when only a conventional-choice
  fallback remains. Flat `questions: true` in `.scribe.yml`; `false` suppresses
  draft §5/§6/§7, the Wrap-Up Pass, and the M3 route; does NOT suppress Standard
  Files prompts, split proposals, ownership prompts, or Decision Drift Resolution.
  Default in the Error Handling defaults list and README config block, with the
  Human-Input-pinning note.

**Acceptance:** rules present in draft SKILL.md; one-question rule conditional;
`questions` and `default_branch` in defaults list and README; suppression list
stated.

## §8. Removals — finding M5

- Step 0's detection paragraph deleted; heading renamed to "### Step 0: Branching
  strategy".
- 9d's replacement quoted in full: "Then check whether the human gate (9e) should
  fire: if the change is `new_draft` or `major_rewrite`, proceed to 9e before
  finalizing. Otherwise, proceed directly to finalize (9f)."
- 9e condition #1 and detection paragraph deleted; conditions renumber to 1
  (new_draft/major_rewrite) and 2, **widened here (this is the owning section; §3
  only references it):** "the rework loop escalated: cap exhausted, same finding
  persisted, or new critical findings appeared". Precedence paragraph and both
  option-set headings rewritten; README's "or autonomous runs" removed.

**Acceptance:** `grep -riE 'autonom(ous|y)' plugins/codebase-scribe` returns
nothing (excluding `IMPROVEMENT-REPORT.md` until wave 7); 9e numbering
self-consistent.

## §9. Delivery

- Branch `scribe-improvements`; PR'd in wave order; **kiali run after wave 3 at the
  earliest** (wave-1 Review Gate guard covers the interim).
- **Waves:**
  1. §2 + §1 + cross-cutting rules (incl. `human_sections`) — kiali-blocking —
     **plus the coherent §4 bundle the migration depends on, moved as a unit:**
     the gitignore seeding (the migration's stated predecessor — untracking
     without ignoring would let `git add -A` re-track the cache), the kiali
     claims/provenance migration itself (it populates `human_sections` and
     `decisions:`; shipping the formula cutover without it would commit zeroed
     `human_input` to the only real deployment during the run window), **the
     decision-id reservation in draft §11 and maintain §6, and Step 3's
     extraction of the new keys** (a fresh kiali clone in the run window has no
     `.claims.yml`; unreserved re-extraction would collide with migrated decision
     ids and wave-4 re-linking would then bind decisions to the wrong claims).
     Cross-wave note: maintain §6's content re-*linking* still arrives in wave 4 —
     inert until then, harmless, since `decisions:` frontmatter is authoritative
     and the reservation already protects the ids.
  2. §5 + snapshot-deletion site (Step 1) — **so `.scribe/` snapshot writes in
     wave 3 find their ignore entry already present (seeded in wave 1)**.
  3. §3 (agent, dispatching-stub reduction, brief contract, M2 reduction,
     snapshots), gated by the **two-question Cursor pre-check** (agent
     dispatchability, identifier form), with question 3 (eval-runner report
     surfacing, via the throwaway fixture) as an in-wave verification whose
     failure branch is the derived-copy fallback. **Accepted residual:** waves 3–5
     carry known-stale scribe-review evals (the P3 judge regexes and old fixture
     shape) until wave 6 regenerates them; the repo README's "a skill without
     passing evals is not mergeable" rule is origin's — on the fork, the agreed
     workflow runs evals manually after PR acceptance (user decision 2026-07-27),
     so the interim is acceptable and recorded.
  4. §4 remainder (migration, seeding, id reservation, and key extraction all
     moved to wave 1; this wave carries the question-pass contract,
     incorporation rules, re-linking, and `resolved_at`).
  5. §6 (strip, then P2), §7, §8.
  6. **Evals:** regenerate all four suites in place against final contracts
     (scribe-review's suite evaluates the agent **indirectly through the
     dispatching stub** — or through the derived-copy fallback if pre-check
     question 3 failed; `/eval-analyze`'s SKILL.md input exists either way). De-P3 carve-out:
     `recommendation_actionable`, `outputs.schema` lines, `review_quality`'s
     prompt, corresponding `eval.md` text. Keep model ids (`claude-opus-4-6`). Old
     fixture architecture removed.
  7. **Cursor audit** + delete `IMPROVEMENT-REPORT.md` + README Cursor-limitations
     section + **P4/P5 (version bump + full README re-read) — last, after the final
     README change** (an earlier revision put these in wave 5, before waves 6–7
     touched the README again).
- **Versioning:** 1.2.6 → 1.3.0 in all four version-carrying files; P4 four-way
  sync check.
- **README (P5):** full re-read at the very end; align every behavioral claim.
- Upstreaming to origin (minus the strip commit): later decision.

## Decisions log (user-ratified 2026-07-27)

1. H7 contract: TL;DR mandatory (mature); Links suggested; skeleton for stubs.
2. #39 strip: upstream.md content only, revertible isolated commit.
3. Provenance: frontmatter `decisions:`; `.claims.yml` stays gitignored.
4. Review agent: no model pin (recorded divergence from repo agent convention).
5. Question-pass counter: `question_passes`, settles at 2.
6. M10: containing-match with exact-match preference.
7. Version: 1.3.0, single bump at the end (wave 7).
8. Spec committed on the feature branch.
9. **human_input redesign: committed `human_sections` list, positive attribution**
   (ratified 2026-07-27, voting round 3).
10. **Gate continuation to voting round 4** (ratified 2026-07-27).

## Revision log

- **rev 6.1 (2026-07-27):** closes the I/J fix-verification findings on rev 6:
  the wave-1 kiali bundle made coherent (gitignore seeding, migration,
  decision-id reservation in both assignment sites, and Step-3 key extraction all
  move together — the rev-6 move had split the migration from its stated
  predecessor and from the reservation a fresh clone needs in the run window);
  migration trigger split (reconstruction on cache presence with `origin: user`
  claims, tracked or not; only the untrack step trackedness-gated) with the
  evidence basis recorded; Error Handling #6 rewritten to cover rung 4's
  refusal; the non-git-directory refusal recorded as a user-visible change;
  "no convention-doc edits" narrowed to eval-layout; the §3 acceptance's
  canonical-copy wording made fallback-aware; the AskUserQuestion option limit
  deferred to implementation-time verification.
- **rev 6 (2026-07-27):** voting round 4 (I, J) union. `human_sections` wiring
  completed: the Wrap-Up Pass added as the fourth answer-incorporation site (with
  post-§8/§10 recompute), §6/§7 restatements rescoped, BOTH §12 checklist items
  rewritten, draft §8's zero-rule deleted outright (formula universal), Safety
  Rule 2 amended to protect human-credited prose verbatim (it was keyed on
  inferred_sections, permitting rewrite-in-place to drop user answers while the
  score claimed credit), heading↔slug mapping specified (draft §4's algorithm,
  fence-aware denominator). Dispatch sentence for sites 1–2 quoted verbatim;
  `docs_dir` added to the 9c brief and agent Inputs; wave-3 pre-check question 3
  given a throwaway fixture; §3 acceptance aligned to the dispatching stub;
  guidance paragraph restated in the new vocabulary with the PASS line untouched;
  contributing.md gains the model-optional clause where the convention lives.
  Question pass: increments on zero-question passes, HARD RULE 1 kept in force,
  9f reset requires both drafted-or-reworked AND not-declined-twice, draft-time
  §6 ask counted separately (three-ask arithmetic stated), stamping exclusion
  enforced at draft §8/§10 themselves. decision_drift row's circular conjunct
  deleted; ladder gains the git-unavailable rung with Error Handling #4 noted;
  only draft's Review Gate item 6 guarded (maintain's item 4 doesn't restate the
  stamp); brief-block edit sites named; kiali migration moved to wave 1 (formula
  cutover must not zero the real deployment); waves 3–5 stale-eval residual
  recorded against the fork's manual-eval workflow; P7 owned by 12d
  full-management; uncovered-modules route continuation stated; git rm --cached
  gated behind AskUserQuestion; P2 question shape specified; content-generating
  docs_dir sites enumerated; §9-deletion numbering semantics fixed; file-scope
  widening recorded; conjunct→disjunct wording; Step 3's pre-existing ###-prune
  bug folded into the edit.
- **rev 5.2 (2026-07-27):** closes the four advisory residuals from the second G/H
  verification round (all targeted rev-5.1 fixes confirmed clean): derived-copy
  fallback gains a generation header and joins P4's sync check; `resolved_at`
  added to the `decisions:` schema and §2's guarded-consumer list, with the
  SHA "max" defined as an ancestry test failing toward re-detection; pre-check
  question 3 relabeled an in-wave verification (its artifacts don't exist
  pre-wave; its failure branch is non-destructive). Also noted, pre-existing and
  unchanged by the redesign: the stored `human_input` is stale in the window
  between a Step-3 orphan prune and the next recomputation.
- **rev 5.1 (2026-07-27):** closes the G/H fix-verification findings on rev 5 (all
  round-3 findings otherwise confirmed resolved): `human_sections` wired into its
  remaining two sites — maintain §8's formula (the steady-state recomputation that
  would have re-manufactured pruning credit) and HARD RULE 4 (the trigger, whose
  text asserted the old basis) — with all sites in wave 1; `human_sections`
  declared a set (no-op on repeat credit); eval design corrected on the precedent
  facts (code-reviewer is agent + full duplicated skill) and made operative: the
  stub *dispatches* the agent and relays its report, pre-check question 3 verifies
  the runner path, with a derived-copy fallback; question-pass stamping stated
  identically in §2 and §4 (neither draft nor rework — no stamp); migration
  section-credit rule made deterministic (exactly-one-body-match); full-clone SHA
  guard wording fixed (§1 reports churn without running its diff);
  decision-drift `resolved_at` field added so the frozen scan does not re-raise
  resolved flags; manual-heading-rename residual recorded against Goal 2.
- **rev 5 (2026-07-27):** voting round 3 (G, H) union. Design changes:
  `human_sections` positive attribution replacing absence-inference (kills both
  failure directions: Step-3 pruning inflation and draft-§8 zero-rule regression;
  no "wholesale rewrite" test needed); **eval relocation reversed** — thin
  `skills/scribe-review/SKILL.md` kept as eval entry point per the in-repo
  code-reviewer agent+skill precedent (resolves the convention-doc conflict,
  `/eval-analyze`'s input, the discovery question, and wave-3 acceptance);
  maintain/9f self-certification closed (scan advances only on content
  regeneration); no-remote ladder rung probes local main/master before the
  current-branch fallback; watch-path repair given a writer (Step 3 frontmatter
  write-back + brief threading); positive redraft instruction for mature topics;
  id reservation extended to maintain §6; absent `question_passes` ⇒ 0 with the
  cross-wave note; §2 acceptance aligned with the rev-4.1 shallow-gate rule; 9e
  widening moved wholly to §8; snapshot deletion moved to Step 1; shallow gate
  extended to maintain §3/§9; collision handling specified; migration
  selection/mapping specified; orphan-mode draft identity fallback; 12e option 1
  identity reads; draft-§9 numbering freeze; P4/P5 moved to wave 7; `color` added
  to agent frontmatter with the model divergence recorded; fence-aware algorithm
  specified and applied to the TL;DR heading test; hook enforces stub TL;DR;
  Step B's no-batch clause deletion scoped; plus ~15 wording/enumeration
  corrections (STATUS.md writer list, "never current" phrasing, wave-2 rationale,
  Error Handling #6, maintain summary ordering, `.claims.yml` bind order,
  three-residual Non-goals additions).
- **rev 4.x (2026-07-27):** voting round 2 (E, F) union + its two verification
  rounds — see git history.
- **rev 3.x / rev 2.x (2026-07-27):** voting round 1 (C, D) and review round 1
  (A, B) unions + their verification rounds — see git history.
