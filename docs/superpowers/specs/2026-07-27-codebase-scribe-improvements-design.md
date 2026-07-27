# codebase-scribe Improvements — Design Spec

- **Date:** 2026-07-27
- **Status:** Approved design, pending review gate
- **Baseline:** fork `TommasoBagassi/ci-utils` @ `b3204c4` (identical to origin main as of this date)
- **Branch:** `scribe-improvements`
- **Background:** full findings analysis in `plugins/codebase-scribe/IMPROVEMENT-REPORT.md`
  (uncommitted working doc, deleted after implementation). This spec is self-contained;
  the report is corroborating detail, not required reading.

## Context

codebase-scribe is a Claude Code / Cursor plugin that generates and maintains agentic
documentation (an `AGENTS.md` hub + topic files under `docs/agents/`) for any codebase,
in three phases: seed (stubs), draft (content + tribal-knowledge questions), maintain
(drift detection). A 2026-07-27 review found correctness and design defects; a parallel
analysis of the plugin's one real deployment (kiali/kiali — docs generated 2026-05-26 by
an earlier plugin version, squash-merged in kiali PR #9656) confirmed several failure
modes in the field.

**Hard constraint:** kiali will run a `/codebase-scribe` completion run immediately
after this work lands. That run directly exercises scan-SHA validation (§2), the
structure contract (§1), and the branch gate (§2) — those changes cannot slip.

The plugin is **manually run** (no automation exists or is planned) and **Cursor
support is real** (actively used).

## Goals

1. The review gate runs in genuinely fresh context, matching what the README claims.
2. User-sourced tribal knowledge survives clones and machine switches.
3. Drift detection cannot be silently disabled by the plugin's own bookkeeping
   (dangling scan SHAs, narrowed watch paths, off-main generation).
4. Mature documentation with domain-specific structure is a first-class citizen, not a
   contract violation.
5. One canonical copy of every internal contract (templates, protocols, orchestration).
6. Eval suites describe the architecture that actually ships.

## Non-goals

- No new features beyond the fixes (no new modes, topics, or output kinds).
- No change to the three-phase design or the three-score system.
- No automation/cron support — the existing half-built autonomous machinery is removed.
- No Cursor feature parity — the goal is an audit and honest documentation of gaps.

---

## §1. Structure contract (two-tier) — findings H7, M1

### Contract

- **New stubs** (created by discover): the full 5-section skeleton is required, unchanged
  (`Key Entry Points`, `Patterns & Conventions`, `Gotchas`, `Dependencies & Context`,
  `Links`, plus TL;DR blockquote).
- **Mature topics** (any topic Step 5 does not classify as `stub` — i.e. real content,
  not placeholder text): the **TL;DR blockquote** (first
  element after the `#` heading) is **mandatory**. A **`## Links` section is strongly
  suggested** but not required. Free-form domain headings (e.g. kiali's "Graph Data
  Model") are fully legitimate and tracked via `inferred_sections` as today.

### Enforcement split

| Layer | Enforces |
|---|---|
| Hook (`doc-validate.sh`) | TL;DR presence only. Silent about Links (per-edit warnings about a suggestion would train users to ignore the hook). |
| Maintain quality checks (§7 of scribe-maintain) | Flags missing TL;DR; advisory note for missing Links section. |
| Review agent | `MISSING_XREF` stays a minor finding (existing tier — no change). |
| Draft | Always writes TL;DR and a Links section in content it generates. The "exactly these 5 `##` headings — no exceptions" language in §3 and the §12 checklist is rewritten to the two-tier contract. |

### Hook fixes (bundled here — same file)

- `hooks.json` matcher: `Write|Edit` → `Write|Edit|MultiEdit`.
- docs_dir awareness: extract `docs_dir` from `.scribe.yml` with grep/sed (no YAML
  parser), fall back to `docs/agents`.
- jq fallback: if `jq` is absent, extract `file_path` with grep/sed; degrade silently
  (exit 0), no stderr noise.
- Warning text becomes advisory (drop "Fix before proceeding" — the hook does not block).

**Acceptance:** a mature topic with domain headings and a TL;DR passes hook + maintain
with no structural warnings; a topic missing its TL;DR is flagged by both; MultiEdit
triggers the hook; the hook validates files under a custom `output.docs_dir`; running
the hook script without jq on PATH produces no stderr output; draft/maintain SKILL.md
no longer contain "exactly these 5" language.

## §2. Drift integrity — findings H6, H3, M7

### Scan-SHA validation (H6)

At run start (orchestrator Step 3/5), every topic's `scan` frontmatter value is
validated: it must be SHA-shaped AND resolve via `git cat-file -e <sha>`. (`scan: null`
is exempt — those topics classify as `stub` as today.) Dangling
SHAs (the normal result of squash-merging a docs branch), the literal `"HEAD"`, or any
malformed value → the topic classifies as `drifted`, never `current`, and freshness is
never reported as 100 for it. A new entry is added to the command's Error Handling
list. Kiali field data: all three distinct scan SHAs in its frontmatter are dangling
and one topic has `"HEAD"` — drift detection is currently dead there while STATUS.md
claims freshness 100.

### watch_paths stay directories (H3)

Draft §9 ("Update Watch Paths") is replaced: draft NEVER narrows watch_paths. They
remain directory globs set at discovery/approval. Draft records the files it actually
read as a new frontmatter list `files_read:` (refreshed each draft pass). The
completeness formula (referenced subdirs of watch_paths / total) is unchanged — and no
longer gameable by narrowing. New files in watched directories are visible to drift.

### Branch gate (M7)

Two independent layers under `branching_strategy: main-only`:
1. Step 0 branch check becomes a hard refusal when on a feature branch — explicit
   refusal wording, no discretion to continue.
2. Finalization (Step 9f) refuses to stamp `freshness: 100` when branch != main —
   a backstop that survives instruction drift.

Field evidence: kiali's docs were generated on a feature branch despite `main-only`,
causing the squash-merge SHA loss above plus a six-week generation→merge staleness gap
(react-scripts→Rsbuild and react-ace→Monaco landed in the gap).

**Acceptance:** a repo with dangling/`"HEAD"` scan values classifies those topics
`drifted` and STATUS.md shows degraded freshness; after a draft pass, frontmatter shows
directory watch_paths + a `files_read` list; adding a new file to a watched directory
classifies the topic drifted on the next run; a `main-only` run on a feature branch
refuses at Step 0; `grep` finds the 9f freshness backstop in the command.

## §3. Review pipeline — findings H1, M2, M4, P3

### scribe-review becomes a plugin agent (H1)

- New `agents/scribe-review.md`: frontmatter (`name`, `description`,
  `tools: Read, Bash, Grep, Glob`), system prompt = the **merged** content of the
  current `skills/scribe-review/SKILL.md` + `skills/prompts/review-adversarial.md`
  (single canonical copy — the two current copies already diverge subtly).
- **No `model` pin** — the plugin ships to environments with different model
  availability (the org runs claude-opus-4-6); the agent inherits the session model.
  Rationale recorded in a comment in the agent file so it isn't "fixed" later.
- `skills/scribe-review/` and `skills/prompts/` are **deleted**.
- Command Step 9c: dispatch the `scribe-review` agent via the **Agent tool**. The
  "NOT the Agent tool" warnings become "dispatch the codebase-scribe:scribe-review
  agent — do NOT hand-write a review prompt for a generic agent".
- Brief change: `source_files` becomes a prioritized list of **paths** (not contents) —
  the agent has filesystem access and reads them itself.

### Snapshots to disk (M4)

Step 8 pre-invocation snapshots are written to `.scribe/snapshots/<topic>.md`,
`.scribe/snapshots/<topic>.claims.yml`, and the heading list — not held in
conversation context. Step 9a classification diffs the on-disk snapshot against the
current file (`git diff --no-index` or equivalent). `.scribe/` is already gitignored;
snapshots are overwritten per run.

### Deduplication (M2) and recommendation fix (P3)

- Review orchestration substeps (9a–9f) exist **only** in the command. Draft's and
  maintain's "Review Gate" sections shrink to: classify what changed + pointer to
  Step 9 + the agent dispatch rule. No restated substeps.
- The review report's Recommendation lines reference `/codebase-scribe` (auto-routing) —
  the currently referenced `/codebase-scribe:scribe-maintain` and `:scribe-draft` slash
  commands do not exist.

**Acceptance:** no reference to scribe-review as a *skill* remains; the review protocol
text exists in exactly one file; a draft run produces an Agent tool dispatch for review;
Step 8/9a instruct file-based snapshotting with no "copy content into context"
instruction; substeps 9a–9f appear only in the command; recommendation lines name only
`/codebase-scribe`.

## §4. Knowledge persistence — findings H2, M9, M3

### Provenance in frontmatter (H2)

Topic frontmatter gains a committed `decisions:` list under `scribe:`:

```yaml
scribe:
  decisions:
    - id: backend-architecture-12
      claim: "PostgreSQL chosen over MongoDB for ACID support"
      context: "MongoDB rejected for lack of ACID; SQLite rejected for no vector search"
      recorded: "2026-05-04"
      source: "internal/store/postgres.go"
```

- Draft (design-decision prompt §6, focus questions §7): when a user answer is
  incorporated, write the `decisions:` entry in frontmatter AND mirror it into
  `.claims.yml` with `origin: user` (cache behavior unchanged).
- `.claims.yml` regeneration (maintain §6): provenance is re-linked **from
  frontmatter** — a re-extracted claim matching a `decisions` entry (by id, or first-50-
  chars match) gets `origin: user` + context + recorded restored. A fresh clone fully
  reconstructs `.claims.yml` including provenance.
- Decision drift detection (maintain §4) reads the frontmatter `decisions:` list
  directly — no longer dependent on `.claims.yml` surviving.
- `.claims.yml` stays gitignored (multi-machine workflow keeps caches local — user
  decision 2026-07-27). README wording updated: the file is now truthfully regenerable.

Field evidence: kiali committed its `.claims.yml` against README guidance, and that
copy is currently the only durable record of real user-answer provenance there
(human_input 25/24/9 on three topics).

### Seed writes .gitignore entries (M9)

Seed/first-run appends `.scribe/` and `<docs_dir>/.claims.yml` to the target repo's
`.gitignore`, idempotently (skip if already present; create the file if absent).
Sequenced after the H2 change since H2 defines what should be ignored.

### Question-pass for unverified topics (M3)

- Orchestrator Step 5/8: `unverified` topics (human_input 0, freshness ≥ 40) route to a
  **question pass** — the draft skill in a lightweight mode that asks the §6 question
  and incorporates an answer, but does NOT re-read source or rewrite content.
- Frontmatter gains `question_passes: N`, incremented on each pass where the user skips.
  At 2, the topic classifies `current`; an answered question resets the counter.

**Acceptance:** delete `.claims.yml`, run maintain on a repo with frontmatter decisions
→ decision drift still functions and the regenerated cache carries `origin: user`; a
seed run on a repo without `.gitignore` entries adds them exactly once (idempotent on
re-run); an unverified topic triggers at most 2 question prompts across runs and its
content is never rewritten by that path.

## §5. Discover and hub management — findings H5, M10, P7

- **Discover creates stubs + STATUS.md only.** Its hub-creation paragraph, hub template,
  and all AGENTS.md instructions (beyond "never touch it") are deleted. Its HARD RULES
  become internally consistent.
- The orchestrator brief to discover includes `docs_dir` explicitly (from `.scribe.yml`
  `output.docs_dir`, default `docs/agents`); discover writes stubs there.
- **All AGENTS.md logic lives in command Step 12**, including creation; the hub template
  exists only there. Step 12b/12c's references to "the discover skill's hub template"
  are replaced by the inline template. The template's `ARCHITECTURE.md` link line is
  conditional on that file existing at write time.
- **Documentation-heading match (M10):** Step 12's append logic matches any `##` heading
  **containing** "Documentation" (case-insensitive) instead of "starting with
  `## Documentation`"; if multiple headings match, the first in document order wins.
  Handles kiali's `## Architecture Documentation` without creating
  a duplicate section. (Configurable-heading and marker-recorded alternatives rejected:
  more state, no observed need.)
- **Stale-content refresh (P7):** full-management mode detects and removes known legacy
  phase-message footers (e.g. "Run `/codebase-scribe` again to draft content for these
  stubs" when no stubs remain) from hubs it owns.

**Acceptance:** seed run with custom `output.docs_dir` puts stubs there; AGENTS.md is
created exactly once, by Step 12; discover's SKILL.md contains no hub content; a hub
whose section is `## Architecture Documentation` gets links appended into that section
(no duplicate created); a scribe-managed hub with the legacy stubs-footer and no
remaining stubs has the footer removed on the next run.

## §6. Standard Files and the #39 strip — finding D5

- **Strip** (org-specific, Red Hat directive content): `docs/upstream.md` generation,
  the upstream-detection block, and the upstream link rule in ARCHITECTURE.md
  generation; drop `docs/upstream.md` from the command Step 13 summary line.
- **Implemented as one isolated, cleanly revertible commit** touching only this
  content — origin-bound PRs re-include it by excluding/reverting that commit.
- **Keep:** README.md / CONTRIBUTING.md / ARCHITECTURE.md handling and the CLAUDE.md /
  GEMINI.md redirect stubs (4–6 lines, generically useful).
- **Prompt batching (P2):** the per-file sequential yes/no prompts are replaced by 1–2
  multiSelect AskUserQuestion calls ("Which missing/thin files should I generate?").

**Acceptance:** no mention of upstream.md or upstream detection remains in the fork's
plugin; `git show <strip-commit>` touches only upstream-related content; the Standard
Files flow asks at most 2 questions.

## §7. Content standards — findings M8, P1, P6

Draft content rules added/changed:

- **Citations:** cite `symbol in file` (function/type name + path), never bare line
  numbers, in topic content. (Kiali natural experiment: the symbol-anchored backend doc
  survived 35 commits at 9/10 claim accuracy; line-number citations in review notes
  were off by 1–3 lines at generation time.)
- **Volatile inventories:** do not enumerate dependency lists, state shapes, or version
  pins unless the review pass mechanically re-verifies them each run — describe where
  the inventory lives instead. (Kiali: frontend doc errors clustered entirely in "tech
  stack" and "state shape" inventory sections.)
- **Claims (P1):** "extract 15-20 claims" → "up to 15–20, proportional to content — do
  not pad small topics" (HARD RULE 2 and §11).
- **Questioning (P6):** §6 may ask zero questions when the only candidate is a
  conventional-choice fallback; `.scribe.yml` gains `questions: false` disabling
  §5–§7 prompting entirely.

**Acceptance:** draft SKILL.md contains the citation and inventory rules; the forced
one-question rule is conditional; `questions: false` is documented in README config.

## §8. Removals — finding M5

All autonomous-mode machinery is deleted: Step 0's "Autonomous detection" paragraph,
Step 9d's autonomous branch, Step 9e trigger condition #1 and its repeated detection
paragraph. Step 9e fires only on `new_draft`/`major_rewrite` classification or rework-
cap exhaustion. (Verified 2026-07-27: no automation exists; the detection method —
model introspection of invocation origin — is unreliable by construction; a headless
run would stall on mandatory AskUserQuestion prompts regardless.)

**Acceptance:** `grep -ri autonomous plugins/codebase-scribe` returns nothing.

## §9. Delivery

- **Branch:** all work on `scribe-improvements` (fork), PR'd to fork main in wave order.
- **Wave order:**
  1. §2 (H6 scan validation, M7 branch gate) + §1 (H7 contract + hook) — the kiali-
     blocking wave.
  2. §5 (discover/hub untangle) + M2 deduplication groundwork.
  3. §3 (review agent).
  4. §4 (provenance, gitignore, question-pass).
  5. §6, §7, §8 + remaining polish (P4 manifest-sync check, P5 README full re-read).
  6. **Evals last:** regenerate eval cases/schemas for discover, draft, maintain against
     the final contracts; add a scribe-review eval with seeded documentation errors
     (wrong-file attribution, deprecated-as-current, changelog language). Keep runner
     config and model ids (`claude-opus-4-6` — matches the org eval environment). Old
     fixture architecture (`.claude/scribe/inventory.yaml`, `AGENT.md`) fully removed.
     Deliverable is *runnable correctness*; runs happen manually post-PR-acceptance.
  7. **Cursor audit last** (M6): audit Skill/Agent tool, AskUserQuestion (+multiSelect),
     hooks semantics in Cursor; fix the cheap, document the rest in a README "Known
     limitations in Cursor" section.
- **Versioning:** single bump 1.2.6 → **1.3.0** at the end; `.claude-plugin/plugin.json`
  and `.cursor-plugin/plugin.json` in lockstep + a ~5-line sync check script (P4).
- **README (P5):** full re-read at the end; every behavioral claim aligned (fresh-
  session review now true, .claims.yml wording, Standard Files list, gitignore section,
  version).
- **Upstreaming to origin** (minus the §6 strip commit) is a later, separate decision —
  out of scope.

## Decisions log (user-ratified 2026-07-27)

1. H7 contract: TL;DR mandatory for mature topics; Links strongly suggested (advisory
   in maintain/review, silent in hook); 5-section skeleton for new stubs only.
2. #39 strip: upstream.md content only, as a revertible isolated commit; CLAUDE.md/
   GEMINI.md redirects and README/CONTRIBUTING/ARCHITECTURE handling kept.
3. Provenance: frontmatter `decisions:` list; `.claims.yml` stays gitignored cache.
4. Review agent: no model pin (inherits session model).
5. Question-pass counter: frontmatter `question_passes`, settles at 2.
6. M10: containing-match for the Documentation heading.
7. Version: 1.3.0, single bump at the end.
8. Spec committed on the feature branch (matches the convention in the user's other
   repos: hermes, food-diary, home-finances, releasepulse all commit
   docs/superpowers/).
