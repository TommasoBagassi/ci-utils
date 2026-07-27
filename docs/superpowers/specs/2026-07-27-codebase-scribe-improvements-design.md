# codebase-scribe Improvements — Design Spec

- **Date:** 2026-07-27 (rev 2 — reworked after review round 1: two fresh Opus reviewers,
  both NOT_APPROVED; all findings addressed in this revision)
- **Status:** Pending review gate round 2
- **Baseline:** fork `TommasoBagassi/ci-utils` @ `b3204c4` (identical to origin main as of this date)
- **Branch:** `scribe-improvements`
- **Background:** full findings analysis in `plugins/codebase-scribe/IMPROVEMENT-REPORT.md`
  (uncommitted working doc, deleted after implementation). This spec is self-contained.

## Context

codebase-scribe is a Claude Code / Cursor plugin that generates and maintains agentic
documentation (an `AGENTS.md` hub + topic files under a configurable docs directory,
default `docs/agents/`) for any codebase, in three phases: seed (stubs), draft (content
+ tribal-knowledge questions), maintain (drift detection). A 2026-07-27 review found
correctness and design defects; a parallel analysis of the plugin's one real deployment
(kiali/kiali — docs generated 2026-05-26 by an earlier plugin version, squash-merged in
kiali PR #9656) confirmed several failure modes in the field.

**Hard constraint:** kiali will run a `/codebase-scribe` completion run immediately
after this work lands. That run directly exercises scan-SHA validation (§2), the
structure contract (§1), the branch gate (§2), and the watch-path repair (§2) — those
changes cannot slip. Note: **kiali's default branch is `master`, not `main`** — the
branch gate is specified against the detected default branch for exactly this reason.

The plugin is **manually run** (no automation exists or is planned). **Cursor support
is real** (actively used); §3 carries a Cursor pre-check because of it.

## Goals

1. The review gate runs in genuinely fresh context, matching what the README claims.
2. User-sourced tribal knowledge survives clones and machine switches.
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
- **Custom `output.docs_dir` becomes genuinely supported** (it is advertised config
  today but hardcoded in ~30 places). This is in scope as a consistency repair, not a
  new feature: the config key already exists and is documented in the README.

---

## §1. Structure contract (two-tier) — findings H7, M1

### Contract

- **Stub topics**: a topic whose body contains the stub placeholder marker
  (`*Stub — will be populated`) or is empty. The full 5-section skeleton is required
  at creation, unchanged (`Key Entry Points`, `Patterns & Conventions`, `Gotchas`,
  `Dependencies & Context`, `Links`, plus TL;DR blockquote).
- **Mature topics**: any topic that is not a stub by the test above. This test is
  locally decidable — the hook, maintain, and draft can each apply it to file content
  alone, with no orchestrator state. For mature topics the **TL;DR blockquote is
  mandatory**, defined positionally: the first non-blank line after the first `# `
  heading line must begin with `>`. A **`## Links` section is strongly suggested** but
  not required. Free-form domain headings (e.g. kiali's "Graph Data Model") are fully
  legitimate and tracked via `inferred_sections` as today.

### Enforcement split

| Layer | Enforces |
|---|---|
| Hook (`doc-validate.sh`) | TL;DR presence only, using the positional definition above (the current `grep -q "^>"` matches any blockquote anywhere and must be replaced). Silent about Links. |
| Maintain quality checks (scribe-maintain §7) | Flags missing TL;DR; advisory note for missing Links section. §7's "Verify each topic file has these 5 `##` headings" is rewritten to the two-tier contract. |
| Review agent | `MISSING_XREF` stays a minor finding (existing tier — no change). |
| Draft | Always writes TL;DR and a Links section in content it generates. Three sites are rewritten to the two-tier contract: §3's "no exceptions, no alternative layouts" structure rule, the §12 validation checklist ("File has exactly these 5 `##` headings"), and **Rework Pipeline step 8**, which restates the §12 checklist ("5 headings, TL;DR, scores, claims") and would otherwise fail-loop reworks on mature domain-headed topics. |

### Hook fixes (bundled here — same file)

- `hooks.json` matcher: `Write|Edit` → `Write|Edit|MultiEdit`. (Verify at
  implementation whether `MultiEdit` still exists as a tool in current Claude Code; if
  it has been folded into `Edit`, the extra alternative is harmless future-proofing —
  no acceptance criterion depends on it.)
- TL;DR check: anchored positional check as defined in the Contract above, replacing
  `grep -q "^>"`.
- docs_dir awareness: the hook resolves `.scribe.yml` from `$CLAUDE_PROJECT_DIR`,
  falling back to the current working directory; extracts `output.docs_dir` with
  grep/sed (no YAML parser), defaulting to `docs/agents`. The path match must accept
  both absolute and repo-relative `file_path` values (the current
  `*/docs/agents/*.md` case pattern requires a leading `/` and never matches
  repo-relative paths).
- jq handling, with explicit precedence: prefer `jq` when present; if absent, extract
  `file_path` with grep/sed; if extraction yields nothing, exit 0 silently. No stderr
  noise on any path.
- Warning text becomes advisory (drop "Fix before proceeding" — the hook does not
  block).

**Acceptance:** a mature topic with domain headings and a TL;DR passes hook + maintain
with no structural warnings; a mature topic whose only blockquote is inside a later
section (no TL;DR) is flagged by both; the hook validates files under a custom
`output.docs_dir` given both absolute and relative paths; running the hook script
without jq on PATH produces no stderr output; no site in draft or maintain (including
draft Rework step 8 and maintain §7) requires all five headings of a non-stub topic.

## §2. Drift integrity — findings H6, H3, M7

### Default-branch detection (prerequisite for the branch gate)

The plugin never hardcodes `main`. The default branch is detected once per run:
`git symbolic-ref refs/remotes/origin/HEAD` (strip the `refs/remotes/origin/` prefix);
if that fails (no remote — Error Handling #6), fall back to the current branch. A
`.scribe.yml` key `branching.default_branch` overrides detection. Everywhere this spec
says "default branch", this detected value is meant. (kiali's default branch is
`master`; a literal `main` comparison would hard-refuse the kiali completion run.)

### Scan-SHA validation (H6)

At orchestrator Step 3 (frontmatter read), every topic's `scan` value is validated:

- **Shape:** must match `^[0-9a-f]{7,40}$` (the README's own example `"a1b2c3d4"` is
  8 hex chars and must remain valid; the literal `"HEAD"` fails this test).
- **Resolution and reachability:** `git cat-file -e <sha>` AND
  `git merge-base --is-ancestor <sha> HEAD`. The reachability test is required because
  `cat-file -e` passes on unreachable pre-squash objects that still exist locally on
  the authoring machine — without it, the same topic classifies `current` on the
  author's clone and `drifted` on a fresh clone.
- **`scan: null`:** not exempt-by-assumption. Step 5's `stub` row today is body-based
  ("Body empty/<50 words, or placeholder text, or has `migration_source`") and does
  not consider `scan`. The rule: `scan: null` + stub body (placeholder marker) →
  `stub` as today; `scan: null` + real body (crashed draft, hand-authored topic) →
  classifies **`undercooked`** (see below), routing it to a full draft.

On validation failure (bad shape, unresolvable, or unreachable): the topic classifies
`drifted`, never `current`, and **its frontmatter `freshness` is set to 0 immediately
at Step 3**, before any STATUS.md regeneration — STATUS.md is a projection of
frontmatter written by three writers (draft's regeneration step, maintain §10, command
Step 10), and none of them consult classifications, so the degraded value must be
persisted where they read. A new entry is added to the command's Error Handling list.

All other frontmatter-SHA consumers are guarded the same way: maintain §1 (diff
scoping), §4 (decision drift), §5 (`flagged_at_sha` — same dangling exposure), and §8
(freshness recomputation) treat an unresolvable/unreachable SHA as full churn and skip
their diff-based branches.

### watch_paths: directories forever, plus a one-time repair (H3)

- Draft's §9 ("Update Watch Paths") is **deleted**: draft NEVER narrows watch_paths.
  They remain the directory globs set at discovery/approval.
- The earlier `files_read` idea from rev 1 is **dropped** — reviewers correctly
  identified it as write-only state with no consumer.
- **One-time repair (required for kiali):** every deployed repo drafted by the current
  plugin already has file-level watch_paths written by the old §9. At Step 3, any
  watch_paths entry that is a file path (has an extension / is not a directory) is
  replaced by its parent directory, deduplicated, and written back to frontmatter.
  Without this, the forward-only rule leaves kiali's drift detection crippled.
- **Classification consequence (deliberate change):** widening watch_paths enlarges
  the completeness denominator (referenced depth-1 subdirs / total subdirs), so scores
  drop. Under the current rules that would mass-classify topics as `undercooked`
  (completeness < 30) and queue redrafts of every kiali-shaped topic on every run,
  forever — a 40-subdir `pkg/` watch can never reach 30% within a 30-file budget. The
  `undercooked` row is therefore redefined: **`undercooked` = completeness < 30 AND
  `scan` is null** (never successfully drafted — the crashed-draft/hand-authored
  case). Topics that completed a draft are never auto-redrafted for low completeness;
  low scores surface in STATUS.md and as review `COVERAGE_GAP` minors. The forced-
  redraft path for damaged topics remains maintain §9's escalation (`escalated` flag +
  `completeness: 0`), which is an explicit, bounded trigger.

### Branch gate (M7)

Two layers, both **conditional on `branching_strategy: main-only`** (the `branch-local`
and `branch-commit` strategies are off-default-branch by definition and must keep
working; detached HEAD falls back to main-only per Error Handling #5 and is treated as
off-branch — the run refuses with the existing "tell user" wording, it does not crash):

1. Step 0's existing check ("tell user and exit" — already an exit today; this is a
   wording hardening, not new behavior) gets explicit refusal wording with no
   discretion to continue, comparing against the **detected default branch**.
2. Finalization (Step 9f) refuses to update **both `freshness` and `scan`** when the
   current branch is not the default branch. The scan half matters most: 9f item 3
   currently stamps `scan` = HEAD unconditionally, and a feature-branch SHA is exactly
   what a squash merge later dangles — the original kiali failure. This backstop is
   also written into the two skills that stamp these fields directly (draft §8/§10,
   maintain §8), because draft writes `freshness: 100` into the file at its own steps
   long before Step 9f runs — a 9f-only guard is bypassed by the writer of record.

**Acceptance:** a repo with dangling, unreachable, or `"HEAD"` scan values classifies
those topics `drifted` and their frontmatter (and therefore STATUS.md) shows
`freshness: 0`; a topic with `scan: null` and a real body classifies `undercooked`;
file-level watch_paths are rewritten to parent directories on the first run and drift
classification for them works from that point on; committing a new file into a watched
directory classifies the topic drifted on the next run; a `main-only` run on a
non-default branch refuses at Step 0 and — if reached by any path — 9f/draft/maintain
refuse to stamp freshness or scan; a `branch-local` run still finalizes normally; a
fully-drafted topic with completeness 20 is NOT classified `undercooked` and is not
redrafted.

## §3. Review pipeline — findings H1, M2, M4, P3

### scribe-review becomes a plugin agent (H1)

- New `agents/scribe-review.md`: frontmatter (`name`, `description`,
  `tools: Read, Bash, Grep, Glob`), system prompt = the **merged** content of the
  current `skills/scribe-review/SKILL.md` + `skills/prompts/review-adversarial.md`.
  The merge must preserve both directions of the current divergence: `SKILL.md`'s
  Scoped Re-Review section and "If in doubt → REWORK_NEEDED" fail-safe, and
  `review-adversarial.md`'s "Common LLM Documentation Errors" list and
  changelog-language → `CONTRADICTION` rule. The merged prompt's **Inputs section is
  rewritten, not copied**: `source_files` is described as a prioritized list of
  *paths* (the current text says "with contents", which contradicts the new brief).
- **No `model` pin** — the plugin ships to environments with different model
  availability (the org runs claude-opus-4-6); the agent inherits the session model.
  The rationale is documented in the README's Documentation Review section (not as a
  comment in the agent body — agent markdown has no comment syntax and an HTML comment
  would become part of the system prompt).
- `skills/scribe-review/SKILL.md` and `skills/prompts/` are **deleted**. The existing
  eval suite under `skills/scribe-review/eval*` is **relocated, not destroyed** — see
  §9 wave 6.
- **All four dispatch sites change**, enumerated (a grep-and-replace implementer must
  not touch the fifth):
  1. Command Step 9c (initial review dispatch).
  2. Command Step 9d item 3 (the scoped re-review after rework — currently "re-invoke
     `scribe-review` via the `Skill` tool"; leaving it would make every rework cycle
     fail on the second review).
  3. Draft's Review Gate step 3.
  4. Maintain §12 step 3.
  Each becomes: "dispatch the `codebase-scribe:scribe-review` agent via the Agent
  tool — do NOT hand-write a review prompt for a generic agent."
  **Preserved verbatim:** command Step 8's rule "Always use the `Skill` tool to invoke
  sub-skills — do NOT spawn a general-purpose `Agent`…", scoped explicitly to the
  draft and maintain skills (which remain skills) so it no longer reads as
  contradicting the review dispatch.
- **Recommendation lines (P3):** the referenced slash commands
  (`/codebase-scribe:scribe-maintain`, `:scribe-draft`) do not exist. The maintain-vs-
  redraft signal is kept, the fake commands are not: "Run `/codebase-scribe` again —
  targeted correction of sections: <list>." vs "Run `/codebase-scribe` again — full
  redraft recommended." The guidance paragraph teaching the reviewer to choose stays.

### Cursor pre-check (gate for the skill deletion)

Before the skill directory is deleted, verify in Cursor that plugin-defined agents are
dispatchable (`plugins/code-reviewer/agents/` already ships three agents through this
marketplace, which is precedent but not proof). If Cursor cannot dispatch plugin
agents, stop and surface the decision — do not proceed with the deletion on the
assumption. The full Cursor audit remains wave 7; this single question cannot wait
that long because §3 removes the fallback.

### Snapshots to disk (M4)

- Step 8 pre-invocation snapshots are written to `.scribe/snapshots/<topic>.md`,
  `.scribe/snapshots/<topic>.claims.yml`, and `.scribe/snapshots/<topic>.headings.txt`
  — not held in conversation context. For a topic file that does not exist yet, a
  zero-byte `<topic>.md` snapshot is written; Step 9a treats absent-or-empty snapshot
  as `new_draft` (this preserves 9a's stub check, which needs pre-skill state).
- Step 9a diffs the on-disk snapshot against the current file (`git diff --no-index`
  or equivalent).
- **Before writing snapshots, Step 8 verifies the target repo's `.gitignore` covers
  `.scribe/` and creates the entry if missing** (same mechanism as §4 M9 — this
  removes any wave-ordering dependency; the plugin repo's own `.gitignore` covers only
  the plugin repo, not target repos).

**Acceptance:** no reference to scribe-review as a *skill* remains in commands or
skills; the review protocol text exists in exactly one file (the agent); all four
dispatch sites use the Agent tool while Step 8's sub-skill rule survives scoped to
draft/maintain; a rework cycle's re-review dispatches the agent; Step 8/9a instruct
file-based snapshotting including the not-yet-existing-topic sentinel; a target repo
without ignore entries gets them before the first snapshot is written; recommendation
lines name only `/codebase-scribe`.

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

- The entry carries `type` so the full existing claim-identity key
  (`{type, topic, first-50-chars}`) is available for matching.
- Draft (design-decision prompt §6, focus questions §7): when a user answer is
  incorporated, write the `decisions:` entry in frontmatter AND mirror it into
  `.claims.yml` with `origin: user`.
- **Re-linking (maintain §6), by content, never by id:** a re-extracted claim matching
  an `active` decision entry on `{type, topic, first-50-chars of claim}` gets
  `origin: user` + context + recorded restored, and **takes the decision entry's id**.
  Sequential id assignment skips every id named in frontmatter `decisions:` (active
  and retired). Rationale: on a fresh clone `.claims.yml` and `_retired_ids` are gone
  and re-extraction renumbers from 1 — id-based matching would graft a user's
  rationale onto an unrelated claim that happens to receive the same number.
- **Retirement is a tombstone, not a deletion:** draft's Decision Drift Resolution
  currently mutates only `.claims.yml`; with frontmatter as the durable record, all
  three resolution outcomes write frontmatter first:
  - "Still valid" → update `recorded` in the frontmatter entry (and mirror to cache).
  - Updated reasoning ("Other") → update `context`/`recorded` in frontmatter (and
    mirror).
  - "No longer relevant" → set `status: retired` on the frontmatter entry (keep it —
    deleting it would let §6 re-link or §4 re-flag the decision on a later pass,
    resurrecting what the user explicitly killed). Retired entries are skipped by
    re-linking and by decision-drift detection.
- Decision drift detection (maintain §4) reads the frontmatter `decisions:` list
  (`status: active` only) — no longer dependent on `.claims.yml` surviving.
- `.claims.yml` stays gitignored (multi-machine workflow keeps caches local — user
  decision 2026-07-27). README wording updated: the file is now truthfully
  regenerable.
- **Migration for already-tracked caches (kiali):** if `<docs_dir>/.claims.yml` is
  tracked in git, first reconstruct frontmatter `decisions:` entries from its
  `origin: user` claims, then `git rm --cached` it. (kiali's committed copy is
  currently the only durable record of its user provenance — a blind untrack would
  destroy exactly the data this section preserves. Field data: human_input 25/24/9 on
  three kiali topics.)

### Orchestrator-owned .gitignore seeding (M9)

**Owner: the orchestrator command, Phase 0 Step 1** (explicitly NOT discover — §5
confines discover to stubs + STATUS.md, and its HARD RULE 2 forbids writing outside
the docs dir). On any run, Step 1 checks the target repo's `.gitignore` for `.scribe/`
and `<docs_dir>/.claims.yml` entries and appends the missing ones, idempotently (skip
if present; create the file if absent). §3's snapshot writer performs the same check
as a belt-and-braces guard.

### Question-pass for unverified topics (M3)

- Orchestrator Step 5/8: `unverified` topics (human_input 0, freshness ≥ 40) route to
  a **question pass** — the draft skill in a lightweight mode that asks the §6
  design-decision question and, on an answer, **appends the answer to the relevant
  section (Dependencies & Context or Gotchas), updates `inferred_sections` per HARD
  RULE 4, recomputes `human_input`, and extracts the corresponding claim + frontmatter
  decision entry**. It does NOT re-read source files and does NOT regenerate any
  existing section. (Rev 1 said the pass "does not rewrite content", which contradicted
  "incorporates an answer" — incorporation IS a content edit. The invariant is
  narrower: *existing prose is never regenerated by this path; answers are appended.*)
- Frontmatter gains `question_passes: N`, incremented on **every** question pass,
  answered or skipped (rev 1 counted only skips, which meant a cooperative user was
  prompted forever). At 2, the topic stops classifying `unverified` and classifies
  `current`. The counter resets only on `new_draft` / `major_rewrite` (a redrafted
  topic is legitimately re-questionable). An answered question moves
  `human_input` above 0, which exits the `unverified` classification on its own.
- **Interaction with `questions: false` (§7):** when questions are disabled, the M3
  route is suppressed entirely and `unverified` topics classify `current`. (Otherwise
  every topic in a questions-off repo is permanently `unverified` and routed to a pass
  that is forbidden from asking anything.)

### Orchestrator visibility (prerequisite for all of §4 and §2)

Command Step 3's frontmatter-extraction list currently enumerates `scan`, `freshness`,
`human_input`, `completeness`, `inferred_sections`, `watch_paths`, `stale_flags`. Add:
`decisions`, `question_passes`. (Without this, Step 5 cannot see the state that §2/§4
classification depends on.)

**Acceptance:** delete `.claims.yml`, run maintain on a repo with frontmatter
decisions → decision drift still functions, the regenerated cache carries
`origin: user` bound to the correct claims (verified by claim text, not id
coincidence), and retired decisions stay retired; a seed run on a repo without
`.gitignore` entries adds them exactly once (idempotent on re-run) via the
orchestrator; an unverified topic accumulates `question_passes` on every pass and
stops being selected at 2; existing prose is never regenerated by the question pass;
with `questions: false` no question pass runs and no topic is classified `unverified`;
Step 3 extracts the two new fields.

## §5. Discover and hub management — findings H5, M10, P7

- **Discover creates stubs + STATUS.md only.** Its hub-creation paragraph, hub
  template, and all AGENTS.md instructions (beyond "never touch it") are deleted. Its
  HARD RULES become internally consistent. The orchestrator brief to discover
  explicitly includes `docs_dir`; discover writes **stubs and STATUS.md** there (both
  paths are hardcoded today).
- **AGENTS.md creation collapses to one path: command Step 12.** Three current sites
  must change, not one:
  1. **Step 1 "Orphan mode hub generation" is deleted** — it is a second creation
     path with its own divergent three-item template. Orphan mode routes to Step 12
     instead, whose 12c "Does not exist" row already handles creation.
  2. Step 12b and 12c's references to "the discover skill's hub template" are
     replaced by the inline template (which lives only in Step 12).
  3. **Step 12e option 1** also says "using the discover skill's hub template" — same
     replacement.
- **Seed-run flow is made explicit:** after Step 2d (discover returns), the seed run
  **continues to Steps 10–13** (STATUS.md fallback, session state, hub management,
  summary) before printing its "run again to draft" message. Today 2d's wording reads
  as terminal; with discover no longer creating the hub, an early exit would leave a
  seeded repo with stubs and no AGENTS.md until the second run.
- **Documentation-heading match (M10), one rule applied uniformly:** prefer an exact
  `## Documentation` heading when one exists; otherwise the first `##` heading
  containing "Documentation" (case-insensitive); create `## Documentation` only when
  neither exists. This rule applies to **12d (both variants), 12d's create-if-missing
  branch, and 12e option 2** — rev 1 fixed only 12d, leaving 12e's exact-match to
  create a duplicate section on kiali-shaped hubs during migration (the very failure
  M10 exists to prevent) and then an unstable append target afterward. The
  `append-only` marker is placed directly above the matched heading. Residual risk,
  accepted: containing-match can select an unintended section (e.g. `## API
  Documentation`) in hubs with several Documentation-like headings; the exact-match
  preference and first-in-document-order rule bound this.
- **Stale-content refresh (P7):** full-management mode removes lines that exactly
  match the known legacy footer strings, currently one: `Run /codebase-scribe again
  to draft content for these stubs` (with or without backticks around the command),
  and only when no stub topics remain. Evidence for this string is field data (the
  kiali hub) — current plugin templates do not write it; the removal list is exact-
  match only, so user prose cannot be caught.
- **docs_dir threading (companion to §1's hook change):** all remaining hardcoded
  `docs/agents` references in behavioral instructions are replaced by "the configured
  docs_dir (default `docs/agents`)": command Steps 3, 10, 12 link-matching; draft's
  claims path, STATUS.md regeneration, README-generation links; maintain's claims
  path, STATUS.md, standard-files link checks. The command resolves `docs_dir` once in
  Phase 0 and passes it in every skill brief. README prose keeps `docs/agents/` as the
  documented default. Step 3's docs_dir-mismatch warning survives as a genuine
  misconfiguration signal.

**Acceptance:** a seed run with custom `output.docs_dir` puts stubs and STATUS.md
there, and the subsequent draft/maintain runs read topics, write claims, and
regenerate STATUS.md in that same directory with no mismatch warning; a fresh seed run
leaves an AGENTS.md on disk (created by Step 12 during that run); deleting AGENTS.md
while keeping the docs dir routes through Step 12, not a Step 1 template; grep finds
no "discover skill's hub template" reference anywhere; a hub whose only section is
`## Architecture Documentation` gets links appended into that section by both 12d and
12e paths (no duplicate created, marker above that heading); a scribe-managed hub with
the legacy stubs-footer and no remaining stubs has exactly that line removed.

## §6. Standard Files and the #39 strip — finding D5

- **Strip** (org-specific, Red Hat directive content), complete list: draft Step A's
  upstream-detection block AND its `docs/upstream.md` classification rules; Step B's
  upstream question text and its entry in the prompt-order line; the `docs/upstream.md`
  template in Step C; the upstream link rule in ARCHITECTURE.md generation; the
  `docs/upstream.md` mention in command Step 13's summary line. (Rev 1 listed only
  three of these sites.)
- **Implemented as one isolated, cleanly revertible commit** touching only this
  content. **Ordering constraint:** the strip commit lands **before** P2's rework of
  Step B — both touch the same prompt loop, and reverting a strip that landed after
  the batching would re-add a sequential prompt into a multiSelect flow. A future
  origin-bound revert therefore re-adds upstream as one more multiSelect option, and
  the revert note in the commit message says so.
- **Eval fixtures:** `skills/scribe-draft/eval/cases/case-004-operator-audience/`
  contains upstream references. Eval fixtures are regenerated wholesale in wave 6; the
  strip's acceptance criterion is scoped to behavioral files (command, skills, hooks,
  README) until then.
- **Keep:** README.md / CONTRIBUTING.md / ARCHITECTURE.md handling and the CLAUDE.md /
  GEMINI.md redirect stubs.
- **Prompt batching (P2, after the strip):** the remaining per-file sequential yes/no
  prompts are replaced by a single multiSelect AskUserQuestion (5 files fit within the
  4-option limit by grouping: one question for README/CONTRIBUTING/ARCHITECTURE, one
  for CLAUDE.md/GEMINI.md — exact grouping is an implementation choice; at most 2
  questions).

**Acceptance:** no mention of upstream.md or upstream detection remains in command,
skills, hooks, or README; `git show <strip-commit>` touches only upstream-related
content; the strip commit predates the P2 commit; the Standard Files flow asks at most
2 questions.

## §7. Content standards — findings M8, P1, P6

Draft content rules added/changed:

- **Citations:** cite `symbol in file` (function/type name + path), never bare line
  numbers, in topic content. (Kiali natural experiment: the symbol-anchored backend
  doc survived 35 commits at 9/10 claim accuracy; line-number citations in review
  notes were off by 1–3 lines at generation time.)
- **Volatile inventories:** do not enumerate dependency lists, state shapes, or
  version pins unless the review pass mechanically re-verifies them each run —
  describe where the inventory lives instead. (Kiali: frontend doc errors clustered
  entirely in "tech stack" and "state shape" inventory sections.)
- **Claims (P1):** "extract 15-20 claims" → "up to 15–20, proportional to content — do
  not pad small topics" (HARD RULE 2 and §11).
- **Questioning (P6):** §6 may ask zero questions when the only candidate is a
  conventional-choice fallback. `.scribe.yml` gains a top-level `questions: true`
  boolean (flat key, consistent with the existing flat `branching_strategy`).
  `questions: false` suppresses: draft §5 (critical-gap questions), §6
  (design-decision prompt), §7 (focus-mode questions), the Wrap-Up Pass, and the §4 M3
  question-pass route. It does NOT suppress: Standard Files prompts, split proposals,
  Step 12 ownership prompts, or Decision Drift Resolution prompts (those maintain
  existing user data rather than soliciting new knowledge). The default (`true`) is
  added to the command's Error Handling defaults list and to the README config block,
  with a README note that disabling questions pins the Human Input score at its
  current value (the README currently advertises it as increasing "naturally").

**Acceptance:** draft SKILL.md contains the citation and inventory rules; the forced
one-question rule is conditional; `questions` appears in the Error Handling defaults
list and README config block with the Human Input caveat; the suppression list above
is stated in the draft skill.

## §8. Removals — finding M5

All autonomous-mode machinery is deleted: Step 0's "Autonomous detection" paragraph,
Step 9d's autonomous branch, Step 9e trigger condition #1 and its repeated detection
paragraph — **plus the dependent renumbering**: 9e's conditions renumber to 1
(new_draft/major_rewrite) and 2 (rework cap exhausted); the Precedence paragraph
(currently phrased as "case 1 AND case 3 → case 3 options") and the two option-set
headings ("For cases 1-2 (change size or autonomy)", "For case 3 (rework cap
exhausted)") are rewritten against the new numbering; README's "or autonomous runs"
phrase (Documentation Review section) is removed.

**Acceptance:** `grep -ri autonomous plugins/codebase-scribe` returns nothing
(excluding eval fixtures until wave 6), and the 9e case numbering is internally
self-consistent (no reference to a case number that no longer exists).

## §9. Delivery

- **Branch:** all work on `scribe-improvements` (fork), PR'd to fork main in wave
  order.
- **Wave order:**
  1. §2 (default-branch detection, scan validation + freshness persistence, watch-path
     repair, `undercooked` redefinition, branch gate incl. skill-side guards) + §1
     (contract + hook) — the kiali-blocking wave.
  2. §5 (discover/hub untangle, orphan-mode collapse, heading match, docs_dir
     threading, seed-flow fix) + §4's orchestrator gitignore seeding (moved up so §3's
     snapshots never land untracked).
  3. §3 (review agent + snapshots), gated by the Cursor agent-dispatch pre-check.
  4. §4 remainder (decisions/provenance lifecycle, question-pass, Step 3 field
     extraction, kiali claims migration).
  5. §6 (strip commit first, then P2), §7, §8, P4/P5 polish.
  6. **Evals:** regenerate eval cases/schemas for discover, draft, maintain against
     the final contracts, and **relocate + regenerate the existing scribe-review eval
     suite** (`skills/scribe-review/eval.yaml` + 5 cases — it exists today and §3
     deletes its parent directory) to `agents/scribe-review/eval*` (mirroring the
     per-skill layout). Its `skill: codebase-scribe:scribe-review` key and
     `dataset.path` must be updated to address the agent — exact runner syntax for
     agent-dispatch is verified against the eval harness at implementation time; the
     `recommendation_actionable` judge is rewritten for the new P3 recommendation
     strings (it currently asserts the removed `scribe-maintain`/`scribe-draft`
     strings, so "keep runner config" explicitly excludes this judge). Keep model ids
     (`claude-opus-4-6` — matches the org eval environment). Old fixture architecture
     (`.claude/scribe/inventory.yaml`, `AGENT.md`) fully removed. Deliverable is
     *runnable correctness*; runs happen manually post-PR-acceptance.
  7. **Cursor audit** (M6): the full audit — AskUserQuestion (+multiSelect), hooks
     semantics, anything the §3 pre-check didn't cover; fix the cheap, document the
     rest in a README "Known limitations in Cursor" section.
- **Versioning:** single bump 1.2.6 → **1.3.0** at the end, in **all four files that
  carry the version**: `plugins/codebase-scribe/.claude-plugin/plugin.json`,
  `plugins/codebase-scribe/.cursor-plugin/plugin.json`, and the codebase-scribe
  entries in the repo-root `.claude-plugin/marketplace.json` and
  `.cursor-plugin/marketplace.json`. The P4 sync check is a four-way comparison
  (plugin.json ↔ marketplace entry, in both trees).
- **README (P5):** full re-read at the end; every behavioral claim aligned (fresh-
  session review now true, .claims.yml wording, Standard Files list, gitignore
  section — now automated, the scan example `"a1b2c3d4"` kept valid by the ≥7-hex
  shape rule, `questions` config, Human Input caveat, version).
- **Upstreaming to origin** (minus the §6 strip commit) is a later, separate
  decision — out of scope.

## Decisions log (user-ratified 2026-07-27)

1. H7 contract: TL;DR mandatory for mature topics; Links strongly suggested (advisory
   in maintain/review, silent in hook); 5-section skeleton for new stubs only.
2. #39 strip: upstream.md content only, as a revertible isolated commit; CLAUDE.md/
   GEMINI.md redirects and README/CONTRIBUTING/ARCHITECTURE handling kept.
3. Provenance: frontmatter `decisions:` list; `.claims.yml` stays gitignored cache.
4. Review agent: no model pin (inherits session model).
5. Question-pass counter: frontmatter `question_passes`, settles at 2.
6. M10: containing-match (with exact-match preference) for the Documentation heading.
7. Version: 1.3.0, single bump at the end.
8. Spec committed on the feature branch (matches the convention in the user's other
   repos).

## Revision log

- **rev 2 (2026-07-27):** reworked after review round 1 (two fresh Opus reviewers,
  both NOT_APPROVED). Major changes: default-branch detection replaces hardcoded
  `main`; branch gate guards `scan` as well as `freshness` and is enforced at the
  writers (draft/maintain), not only 9f; scan validation adds reachability, a shape
  definition, `scan: null` handling, freshness persistence, and guards on all
  frontmatter-SHA git calls; one-time watch-path repair for deployed repos;
  `undercooked` redefined to kill the redraft loop; `files_read` dropped (write-only);
  AGENTS.md creation collapsed from three sites (orphan mode deleted); seed flow made
  explicit; heading match unified across 12d/12e with exact-match preference; 9d's
  Skill-tool re-review added to the dispatch-site list; Step 8 sub-skill rule
  explicitly preserved; merged agent Inputs rewritten; Cursor pre-check gates the
  skill deletion; snapshot sentinel + heading-list path + gitignore guard; decisions
  entries gain `type` and `status` tombstones, re-linking is content-based with id
  reservation; gitignore seeding assigned to the orchestrator; question-pass
  contradiction resolved (append-only incorporation), counter counts all passes,
  resets on redraft, suppressed by `questions: false`; Step 3 extraction list
  extended; strip list completed (Step A/B sites) + ordering vs P2; question config
  key defined flat with suppression list and defaults-list entry; 9e renumbering
  specified; version bump covers all four files; review eval suite relocated instead
  of silently destroyed.
