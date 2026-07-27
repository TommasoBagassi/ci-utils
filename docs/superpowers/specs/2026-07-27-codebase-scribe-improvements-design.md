# codebase-scribe Improvements — Design Spec

- **Date:** 2026-07-27 (rev 3 — reworked after voting round 1: two fresh Opus voters,
  both NOT_APPROVED; the full union of their findings is addressed in this revision)
- **Status:** Pending review gate voting round 2
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
2. User-sourced tribal knowledge survives clones, machine switches, **and redrafts of
   the topic that holds it**.
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
  today but hardcoded in ~30 places). In scope as a consistency repair, not a new
  feature. The `branch-local` strategy's docs_dir override is specified (§5) but
  `branch-local` itself remains as-is otherwise.

---

## Frontmatter key preservation (cross-cutting rule)

Several sections add committed frontmatter keys (`decisions`, `question_passes`,
`review_notes` already exists). **General rule, stated once here and referenced by
every writer: any frontmatter key not explicitly named by a writer is carried through
unchanged.** Specifically, draft §10's enumerated write list ("YAML frontmatter (scan
SHA = current HEAD, scores, inferred_sections, watch_paths, empty stale_flags)") is
amended to add "…, and preserved verbatim: `decisions`, `question_passes`,
`review_notes`, and any other keys present". Without this, the first `drifted` redraft
of a topic destroys its `decisions:` list — the exact data §4 exists to make durable —
and resets `question_passes`, restarting the §4 loop.

**Acceptance:** redraft a topic carrying a `decisions:` entry and a `question_passes`
value; both survive verbatim in the rewritten frontmatter.

## §1. Structure contract (two-tier) — findings H7, M1

### Contract

- **Stub topics**: a topic whose body is empty or contains the stub placeholder marker
  (`*Stub — will be populated`). The full 5-section skeleton is required at creation,
  unchanged (`Key Entry Points`, `Patterns & Conventions`, `Gotchas`, `Dependencies &
  Context`, `Links`, plus TL;DR blockquote).
- **Mature topics**: any topic that is not a stub by the test above. The test is
  locally decidable — hook, maintain, and draft apply it to file content alone. For
  mature topics the **TL;DR blockquote is mandatory**, defined positionally: **after
  the closing `---` of YAML frontmatter**, the first non-blank line following the
  first `# ` heading line must begin with `>`. A file with no `# ` heading at all is
  flagged as missing its TL;DR (that is the malformed case where a warning matters
  most). A **`## Links` section is strongly suggested** but not required. Free-form
  domain headings (e.g. kiali's "Graph Data Model") are fully legitimate and tracked
  via `inferred_sections` as today.
- **One stub test everywhere:** command Step 5's `stub` row currently reads "Body
  empty/<50 words, or placeholder text, or has `migration_source`". It is rewritten to
  the same test as everyone else: "body is empty or contains the stub placeholder
  marker, or has `migration_source`" — the `<50 words` conjunct is dropped. (Without
  this, a 30-word hand-authored topic is simultaneously mature to the hook, `stub` to
  Step 5, and `undercooked` to §2 — three components disagreeing about one file, with
  Step 5's priority-1 row winning and shadowing §2's crashed-draft route.)

### Enforcement split

| Layer | Enforces |
|---|---|
| Hook (`doc-validate.sh`) | On mature topics: TL;DR presence only, positional definition above (the current `grep -q "^>"` matches any blockquote anywhere and must be replaced). On stub topics: the 5-section skeleton (the stub test is locally decidable, so the hook keeps today's section loop for stubs — otherwise the skeleton requirement would be enforced by no layer). Silent about Links. |
| Maintain quality checks (scribe-maintain §7) | Flags missing TL;DR; advisory note for missing Links section. §7's "Verify each topic file has these 5 `##` headings" is rewritten to the two-tier contract. |
| Review agent | `MISSING_XREF` stays a minor finding (existing tier — no change). |
| Draft | Always writes TL;DR and a Links section in content it generates. **Four** sites are rewritten to the two-tier contract: §3's "no exceptions, no alternative layouts" structure rule; the Content standards rule "**Every topic MUST have all 5 sections**" (scoped after the rewrite to content draft generates for a *stub*); the §12 validation checklist ("File has exactly these 5 `##` headings"); and Rework Pipeline step 8, which restates the §12 checklist ("5 headings, TL;DR, scores, claims") and would otherwise fail-loop reworks on mature domain-headed topics. |

### Hook fixes (bundled here — same file)

- `hooks.json` matcher: `Write|Edit` → `Write|Edit|MultiEdit`. (Verify at
  implementation whether `MultiEdit` still exists as a tool; if folded into `Edit`,
  the extra alternative is harmless future-proofing — no acceptance criterion depends
  on it.)
- TL;DR check: anchored positional check as defined in the Contract above (frontmatter
  skipped first; no-heading files flagged), replacing `grep -q "^>"`.
- docs_dir awareness: the hook resolves `.scribe.yml` from `$CLAUDE_PROJECT_DIR`,
  falling back to the current working directory; extracts `output.docs_dir` with
  grep/sed (no YAML parser), defaulting to `docs/agents`. The path match must accept
  both absolute and repo-relative `file_path` values (the current `*/docs/agents/*.md`
  case pattern requires a leading `/` and never matches repo-relative paths). Known,
  documented gap: the hook cannot see the `branch-local` runtime override (§5), so
  topics written under `.scribe/branch-docs/` are not validated.
- jq handling, with explicit precedence: prefer `jq` when present; if absent, extract
  `file_path` with grep/sed; if extraction yields nothing, exit 0 silently. No stderr
  noise on any path.
- Warning text becomes advisory (drop "Fix before proceeding" — the hook does not
  block).

**Acceptance:** a mature topic with domain headings and a TL;DR passes hook + maintain
with no structural warnings; a mature topic whose only blockquote is inside a later
section (no TL;DR) is flagged by both, as is a topic file with no `# ` heading; a stub
missing a skeleton section is flagged by the hook; the hook validates files under a
custom `output.docs_dir` given both absolute and relative paths; running the hook
script without jq on PATH produces no stderr output; no site in draft or maintain
(including all four draft sites and maintain §7) requires all five headings of a
non-stub topic; command Step 5's stub row contains no word-count test.

## §2. Drift integrity — findings H6, H3, M7

### Default-branch detection (prerequisite for the branch gate)

The plugin never hardcodes `main`. The default branch is detected once per run by the
orchestrator, with a **fail-closed** ladder — `refs/remotes/origin/HEAD` is written by
`git clone` but not by `git remote add`, and is absent in CI checkouts, so its failure
must not be treated as "no remote":

1. `.scribe.yml` `default_branch`, if set — overrides everything. (Flat key,
   consistent with the existing flat `branching_strategy`; added to the command's
   Error Handling defaults list — default: auto-detect — and the README config block,
   alongside §7's `questions`.)
2. `git symbolic-ref refs/remotes/origin/HEAD` (strip the `refs/remotes/origin/`
   prefix).
3. Probe `git rev-parse --verify origin/main`, then `origin/master`.
4. If a remote exists but none of the above resolves: under `main-only`, **refuse the
   run** and tell the user to set `default_branch` — never fall back to the current
   branch, which would compare the branch against itself and pass the gate on exactly
   the feature-branch runs it exists to block.
5. Only when no remote exists at all (Error Handling #6): fall back to the current
   branch.

**Threading (the skills never re-detect):** the orchestrator passes `default_branch`,
`branching_strategy`, and `current_branch` in every skill brief — mirroring §5's
`docs_dir` threading. Draft and maintain use the passed values for their §2 guards;
re-running the ladder inside a skill could diverge from the orchestrator's result and
is forbidden.

**Error Handling section updates (all in the command):**
- The preamble "Handle every error gracefully — warn and continue with defaults" gains
  "…except where an entry below explicitly refuses the run."
- Entry #5 (detached HEAD) is rewritten: under `main-only`, detached HEAD is treated
  as off-branch and the run refuses (a graceful message, not a crash); `default_branch`
  config does not rescue a detached HEAD.
- A new entry covers scan validation (below), including its shallow-clone interaction
  with entry #4.

### Scan-SHA validation (H6)

At orchestrator Step 3 (frontmatter read), every topic's **non-null** `scan` value is
validated. **`scan: null` is never a validation failure** — it is handled exclusively
by the classification rule below (a null scan failing the shape test would classify
`drifted` at priority 3 and shadow the `undercooked` route this section defines).

- **Shallow-clone gate first:** if `git rev-parse --is-shallow-repository` is `true`,
  skip scan validation entirely and warn, per Error Handling #4 ("shallow clone — skip
  git-dependent features") — in a `--depth=1` clone every historical object is beyond
  the graft boundary and validation would mass-write `freshness: 0` into every topic
  of a perfectly healthy repo.
- **Shape:** must match `^[0-9a-f]{7,40}$` (the README's own example `"a1b2c3d4"` is
  8 hex chars and must remain valid; the literal `"HEAD"` fails this test).
- **Resolution and reachability:** `git cat-file -e <sha>` AND
  `git merge-base --is-ancestor <sha> HEAD`. The reachability test is required because
  `cat-file -e` passes on unreachable pre-squash objects that still exist locally on
  the authoring machine — without it, the same topic classifies `current` on the
  author's clone and `drifted` on a fresh clone.

On validation failure (bad shape, unresolvable, or unreachable — non-null values
only): the topic classifies `drifted`, never `current`, and **its frontmatter
`freshness` is set to 0 immediately at Step 3**, before any STATUS.md regeneration —
STATUS.md is a projection of frontmatter, and **every** STATUS.md writer (draft's
regeneration step, maintain §10, command Step 10, command 9f item 6, and discover on
seed) reads frontmatter only, so the degraded value must be persisted where they read.

**Other stored-SHA consumers, all guarded:**
- maintain §1 (diff scoping), §4 (decision drift), §5 (`flagged_at_sha` — same
  dangling exposure), §8 (freshness recomputation): an unresolvable/unreachable SHA is
  treated as full churn; diff-based branches are skipped.
- **Command Step 4 (session validation):** an unresolvable or unreachable
  `last_active_sha` discards the session — same test as the frontmatter guard.
  (`.scribe/` is gitignored, so session.json survives exactly the squash merge that
  dangles its SHA; `git rev-list --count <dangling>..HEAD` would error mid-check.)
- `_meta.<topic>_extracted_at` in `.claims.yml` is a stored SHA that needs **no**
  guard: it is only ever compared for equality, and a mismatch triggers re-extraction,
  which is the safe direction. Noted so a future reader does not re-derive this.

### watch_paths: directories forever, plus a one-time repair (H3)

- Draft's §9 ("Update Watch Paths") is **deleted**: draft NEVER narrows watch_paths.
  They remain the directory globs set at discovery/approval.
- **One-time repair (required for kiali):** at Step 3, the repair applies to every
  watch_paths entry, with the file-vs-directory test defined **by path shape, not
  filesystem state**: an entry that does not resolve to an existing directory is
  replaced by its parent (the path minus its last `/`-segment), deduplicated; an entry
  with no `/` (repo-root level: `Makefile`, `Dockerfile`) is preserved as-is. This
  handles existing files, **and files that were renamed or deleted after drafting** —
  the expected kiali case, where a `test -f` based rule would silently preserve
  dangling entries as permanently drift-blind diff scopes. The repair is purely
  mechanical — frontmatter records no provenance, so origin (Step 2b approval vs old
  draft-§9 narrowing) is not distinguishable: subdirectory entries are widened
  regardless of origin (over-widening a deliberately approved file costs only extra
  drift sensitivity); root-level entries are preserved regardless of origin. The
  repair is idempotent (directories resolve as directories on the second pass).
- **Classification consequence (deliberate change):** widening watch_paths enlarges
  the completeness denominator, so scores drop. Under current rules that would
  mass-classify topics as `undercooked` (completeness < 30) and queue redrafts of
  every kiali-shaped topic forever — a 40-subdir `pkg/` watch can never reach 30%
  within a 30-file budget. Two Step 5 rows are therefore rewritten:
  - **`undercooked` = `scan` is null AND the body is not a stub** (never successfully
    drafted — crashed-draft/hand-authored case, at any completeness score). Topics
    that completed a draft are never auto-redrafted for low completeness; low scores
    surface in STATUS.md and as review `COVERAGE_GAP` minors. The forced-redraft path
    for damaged topics remains maintain §9's escalation (`escalated` flag +
    `completeness: 0`) — and maintain §9 step 1's parenthetical ("this triggers the
    `undercooked` classification in the orchestrator's Step 5") is rewritten to name
    the `escalated` classification, which is what actually routes it.
  - **`current` becomes a true default: "no other row matched."** The current row's
    "scores adequate + scan matches HEAD" is dropped — after the `undercooked`
    change, a fully-drafted completeness-20 topic and §4's settled/questions-off
    topics must land somewhere, and today's wording matches no row for them.
- Under `branch-local`, Step 3's repairs and freshness degradation apply to the tree
  Step 3 actually read (the branch-docs tree) — no special-casing.

### Branch gate (M7)

Two layers, both **conditional on `branching_strategy: main-only`** (`branch-local` /
`branch-commit` are off-default-branch by definition and must keep working):

1. Step 0's existing check ("tell user and exit" — already an exit today; this is a
   wording hardening, not new behavior) gets explicit refusal wording with no
   discretion to continue, comparing against the **detected default branch**.
2. Finalization (Step 9f) refuses to update **both `freshness` and `scan`** when the
   current branch is not the default branch. The scan half matters most: 9f item 3
   currently stamps `scan` = HEAD unconditionally, and a feature-branch SHA is exactly
   what a squash merge later dangles — the original kiali failure. The same guard is
   written into **all skill-side stamping sites: draft §8/§10 AND draft Rework step 6
   ("Update freshness only. Set `freshness: 100`" — reachable via 9d without passing
   §8/§10), and maintain §8** — because draft writes `freshness: 100` into the file
   long before Step 9f runs; a 9f-only guard is bypassed by the writer of record. The
   skills read the branch state from the brief (threading above), never re-detect.

**Acceptance:** a repo with dangling, unreachable, or `"HEAD"` scan values classifies
those topics `drifted` and their frontmatter (and therefore STATUS.md) shows
`freshness: 0`; a shallow clone skips validation with a warning and no frontmatter is
degraded; a topic with `scan: null` and a real body classifies `undercooked` (not
`drifted`); a session whose `last_active_sha` is dangling is discarded; subdirectory
file-level watch_paths — including entries for since-renamed files — are rewritten to
parent directories on the first run (root-level file entries preserved) and drift
classification works from that point on; committing a new file into a watched
directory classifies the topic drifted on the next run; a `main-only` run on a
non-default branch refuses at Step 0 and — if reached by any path, including rework —
9f/draft/maintain refuse to stamp freshness or scan; a `branch-local` run still
finalizes normally; a fully-drafted topic with completeness 20 classifies `current`
and is not redrafted.

## §3. Review pipeline — findings H1, M2, M4, P3

### scribe-review becomes a plugin agent (H1)

- New `agents/scribe-review.md`: frontmatter (`name`, `description`,
  `tools: Read, Bash, Grep, Glob`), system prompt = the **merged** content of the
  current `skills/scribe-review/SKILL.md` + `skills/prompts/review-adversarial.md`.
  The merge must preserve both directions of the current divergence: `SKILL.md`'s
  Scoped Re-Review section and "If in doubt → REWORK_NEEDED" fail-safe, and
  `review-adversarial.md`'s "Common LLM Documentation Errors" list and
  changelog-language → `CONTRADICTION` rule.
- **Brief contract, both sides changed together:** the brief is passed as the Agent
  tool's **prompt** (the Agent tool has no `args` parameter — 9c's and 9d item 3's
  "pass as `args`" phrasing is rewritten accordingly). 9c's `source_files` block is
  rewritten to **paths only** — the "Files over 500 lines: include excerpts" clause
  is dropped; the agent reads file contents itself via its tools. The merged agent
  prompt's Inputs section is rewritten to match (the current text says "with
  contents").
- **No `model` pin** — the plugin ships to environments with different model
  availability (the org runs claude-opus-4-6); the agent inherits the session model.
  The rationale is documented in the README's Documentation Review section (not as a
  comment in the agent body — agent markdown has no comment syntax and an HTML comment
  would become part of the system prompt).
- `skills/scribe-review/SKILL.md` and `skills/prompts/` are **deleted**, and the eval
  tree (`eval.yaml`, `eval.md`, `eval/cases/**`) is **relocated in the same wave** to
  `plugins/codebase-scribe/evals/scribe-review/` (a `git mv` plus key edits — see §9
  wave 3/6 split) so no wave leaves a dangling `skill:` reference under `skills/`.
- **Dispatch sites, enumerated** (a grep-and-replace implementer must not touch
  Step 8's sub-skill rule):
  1. Command Step 9c (initial dispatch) — including its trailing sentence "The skill
     will follow the review protocol in `skills/scribe-review/SKILL.md` and the
     adversarial prompt in `skills/prompts/review-adversarial.md` automatically",
     which names both deleted files and is rewritten as part of this site.
  2. Command Step 9d item 3 (scoped re-review after rework — currently "re-invoke
     `scribe-review` via the `Skill` tool"; leaving it would make every rework cycle
     fail on the second review).
  3. Draft's Review Gate (see the M2 reduction below).
  4. Maintain §12 (same).
  Each dispatch becomes: "dispatch the `codebase-scribe:scribe-review` agent via the
  Agent tool, passing the brief as its prompt — do NOT hand-write a review prompt for
  a generic agent."
  **Step 8's sub-skill rule is preserved in substance, with a scope clause added**
  (not "verbatim" — the two would contradict): replacement text: "Always use the
  `Skill` tool to invoke the draft and maintain sub-skills — do NOT spawn a
  general-purpose `Agent` with a hand-written prompt that replicates a skill's
  behavior. (Review dispatch is the exception: it uses the dedicated
  `codebase-scribe:scribe-review` agent — see Step 9c.)"
- **M2 dedup, reinstated (rev 2's "they only point at Step 9" was a false premise —
  both sections restate substeps 9a–9f with paraphrased behavior, including a third
  "update scan SHA" statement outside §2's writer list and a divergent stub-check
  rule):** draft's Review Gate and maintain §12 are each reduced to: "Follow Step 9
  (Review Orchestration) in `commands/codebase-scribe.md` for every topic modified in
  this pass — dispatching reviews via the `codebase-scribe:scribe-review` agent as
  Step 9c specifies — and return to the orchestrator only after it completes for all
  of them." The numbered substep restatements are deleted. Substeps 9a–9f then exist
  only in the command.
- **Recommendation lines (P3):** the referenced slash commands
  (`/codebase-scribe:scribe-maintain`, `:scribe-draft`) do not exist. The maintain-vs-
  redraft signal is kept, the fake commands are not: "Run `/codebase-scribe` again —
  targeted correction of sections: <list>." vs "Run `/codebase-scribe` again — full
  redraft recommended." The guidance paragraph teaching the reviewer to choose stays.

### Cursor pre-check (gate for the skill deletion)

Before the skill directory's SKILL.md is deleted, verify in Cursor that
plugin-defined agents are dispatchable (`plugins/code-reviewer/agents/` already ships
three agents through this marketplace — precedent, not proof). If Cursor cannot
dispatch plugin agents, stop and surface the decision — do not proceed on the
assumption. The full Cursor audit remains wave 7; this single question cannot wait,
because §3 removes the fallback.

### Snapshots to disk (M4)

- **Step 8 deletes `.scribe/snapshots/` and rewrites it at the start of every run**
  (snapshots must never outlive their run — a stale snapshot diffed by a later run
  would produce spurious `major_rewrite` classifications and human gates). Snapshots
  written per topic: `.scribe/snapshots/<topic>.md` (full file, including
  frontmatter), `<topic>.claims.yml`, `<topic>.headings.txt`.
- **9a item 1 keeps today's semantics:** it reads the pre-skill `scan` value **from
  the snapshot's frontmatter** — a discover-created stub is a non-empty ~20-line file,
  so an absent-or-empty test alone would misclassify the dominant `new_draft` case as
  `major_rewrite`. The zero-byte sentinel is an **additional** `new_draft` trigger:
  for a topic file that did not exist at Step 8, a zero-byte `<topic>.md` snapshot is
  written, and 9a treats absent-or-empty snapshot as `new_draft`.
- A missing snapshot for a topic that was nonetheless modified classifies
  `major_rewrite` (fail toward review, never away from it).
- Step 9a diffs the on-disk snapshot against the current file (`git diff --no-index`
  or equivalent).
- **Before writing snapshots, Step 8 verifies the target repo's `.gitignore` covers
  `.scribe/` and creates the entry if missing** (same mechanism as §4's seeding —
  belt-and-braces; the plugin repo's own `.gitignore` covers only the plugin repo).

**Acceptance:** no reference to scribe-review as a *skill* remains anywhere under
`commands/` or `skills/` at the end of the §3 wave (the eval tree having moved to
`evals/` in the same wave); the review protocol text exists in exactly one file (the
agent); all dispatch sites use the Agent tool with the brief as prompt while Step 8's
sub-skill rule survives with its scope clause; substeps 9a–9f exist only in the
command; a rework cycle's re-review dispatches the agent; the first draft of a
discover-created stub classifies `new_draft` (not `major_rewrite`); a topic modified
without a snapshot classifies `major_rewrite`; snapshots from a previous run never
survive into the next; a target repo without ignore entries gets them before the
first snapshot is written; recommendation lines name only `/codebase-scribe`.

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

- Preservation across redrafts is guaranteed by the cross-cutting frontmatter rule at
  the top of this spec (draft §10's field list amended).
- The entry carries `type` so the full existing claim-identity key
  (`{type, topic, first-50-chars}`) is available for matching.
- Draft (design-decision prompt §6, focus questions §7): when a user answer is
  incorporated, write the `decisions:` entry in frontmatter AND mirror it into
  `.claims.yml` with `origin: user`.
- **Answer incorporation target (also fixes draft §6/§7's current wording):** §1
  makes `Gotchas` and `Dependencies & Context` optional on mature topics, so "append
  to Dependencies & Context or Gotchas" needs a fallback: **if neither section
  exists, append the answer to the last `##` section of the topic, adding that
  section's slug to `inferred_sections` first and then removing it per HARD RULE 4,
  so `human_input` reflects the input.** Without this, the M3 pass on kiali's
  domain-headed topics would have nowhere to write, `human_input` could never move,
  and the user's answer would be silently discarded on exactly the population §1
  legitimizes.
- **Re-linking (maintain §6), by content, never by id:** a re-extracted claim matching
  an `active` decision entry on `{type, topic, first-50-chars of claim}` gets
  `origin: user` + context + recorded restored, and takes the decision entry's id.
  Sequential id assignment skips every id named in frontmatter `decisions:` (active
  and retired). **Uniqueness guards:** if more than one re-extracted claim matches one
  decision entry, the first in document order binds and the others keep sequential
  ids; if one claim matches more than one active decision entry, it binds none and the
  affected decisions are reported as unmatched. Rationale for content-matching: on a
  fresh clone `.claims.yml` and `_retired_ids` are gone and re-extraction renumbers
  from 1 — id-based matching would graft a user's rationale onto an unrelated claim.
- **Residual, accepted:** re-extraction is an LLM operation, so a reworded claim can
  fail the first-50-chars match and drop the provenance link. This fails *safe* —
  provenance is lost, never grafted onto the wrong claim. Maintain reports any
  `active` decision that found no matching claim on a re-link pass, so the user can
  re-link or retire it.
- **Retirement is a tombstone, not a deletion:** all three Decision Drift Resolution
  outcomes write frontmatter first — "Still valid" updates `recorded`; updated
  reasoning updates `context`/`recorded`; "No longer relevant" sets `status: retired`
  on the entry (kept — deleting it would let §6 re-link or §4 re-flag the decision
  later, resurrecting what the user explicitly killed). Retired entries are skipped by
  re-linking and by decision-drift detection.
- Decision drift detection (maintain §4) reads the frontmatter `decisions:` list
  (`status: active` only) — no longer dependent on `.claims.yml` surviving.
- `.claims.yml` stays gitignored (multi-machine workflow keeps caches local — user
  decision 2026-07-27). README wording updated: the file is now truthfully
  regenerable.
- **Migration for already-tracked caches (kiali) — owner: command Phase 0 Step 1,
  immediately after gitignore seeding, once per repo, idempotent (a no-op when the
  file is untracked or `decisions:` entries already exist):** if
  `<docs_dir>/.claims.yml` is tracked in git, first reconstruct frontmatter
  `decisions:` entries from its `origin: user` claims, then `git rm --cached` it. The
  resulting staged untrack is **reported in the Step 13 summary with an explicit
  instruction to commit it** — the plugin does not commit (under `main-only` it never
  commits), and an uncommitted staged deletion that the user resets would silently
  re-track the file, so the user must be told. (kiali field data: its committed copy
  is currently the only durable record of human_input 25/24/9 on three topics — a
  blind untrack would destroy exactly the data this section preserves.)

### Orchestrator-owned .gitignore seeding (M9)

**Owner: the orchestrator command, Phase 0 Step 1** (explicitly NOT discover — §5
confines discover to stubs + STATUS.md, and its HARD RULE 2 forbids writing outside
the docs dir). On any run, Step 1 checks the target repo's `.gitignore` for `.scribe/`
and `<docs_dir>/.claims.yml` entries and appends the missing ones, idempotently (skip
if present; create the file if absent). §3's snapshot writer performs the same check
as a belt-and-braces guard.

### Question-pass for unverified topics (M3)

The pass gets the same explicit contract rework mode has (flag, pipeline, exclusion
list):

- **Selection:** command Step 8's `unverified` row is respecified to invoke the draft
  skill with `question_pass: true` in the brief (batched, as today).
- **Pipeline:** ask the §6 design-decision question for the topic; on an answer,
  append it per the incorporation-target rule above, update `inferred_sections` per
  HARD RULE 4, recompute `human_input`, extract the corresponding claim and write the
  frontmatter `decisions:` entry; increment `question_passes` (the pass itself writes
  the increment, answered or skipped — counting only skips would prompt a cooperative
  user forever). The pass's output flows through Step 9 (review orchestration) like
  any draft output — an appended answer typically classifies `claim_change`.
- **What the question pass does NOT do:** read source files; regenerate any existing
  section; ask focus-mode (§7) or critical-gap (§5) questions; run the Standard Files
  block.
- **Settling:** at `question_passes: 2`, the topic stops classifying `unverified` and
  classifies `current`. **The reset to 0 is written by 9f** when the just-computed 9a
  classification is `new_draft` or `major_rewrite` (a redrafted topic is legitimately
  re-questionable) — the pass increments, 9f resets; no other writer.
- **Interaction with `questions: false` (§7):** the M3 route is suppressed entirely
  and `unverified` topics classify `current`.

### Orchestrator visibility (prerequisite for all of §4 and §2)

Command Step 3's frontmatter-extraction list currently enumerates `scan`, `freshness`,
`human_input`, `completeness`, `inferred_sections`, `watch_paths`, `stale_flags`. Add:
`decisions`, `question_passes`. (Without this, Step 5 cannot see the state §2/§4
classification depends on.)

**Acceptance:** delete `.claims.yml`, run maintain on a repo with frontmatter
decisions → decision drift still functions, the regenerated cache carries
`origin: user` bound to the correct claims (verified by claim text, not id
coincidence), retired decisions stay retired, and duplicate-id states are impossible
(uniqueness guards); an answer on a domain-headed topic with neither default section
is appended to its last section and raises `human_input`; a seed run on a repo
without `.gitignore` entries adds them exactly once via the orchestrator; an
unverified topic accumulates `question_passes` on every pass, stops being selected at
2, and the counter resets only via 9f on `new_draft`/`major_rewrite`; with
`questions: false` no question pass runs and no topic classifies `unverified`; the
kiali migration reconstructs `decisions:` before untracking and the staged untrack is
reported in the summary; Step 3 extracts the two new fields.

## §5. Discover and hub management — findings H5, M10, P7

- **Discover creates stubs + STATUS.md only.** Its hub-creation paragraph, hub
  template, and all AGENTS.md instructions (beyond "never touch it") are deleted. Its
  HARD RULES become internally consistent. The orchestrator brief to discover
  explicitly includes `docs_dir`; discover writes **stubs and STATUS.md** there (both
  paths are hardcoded today).
- **AGENTS.md creation collapses to one path: command Step 12**, via a new canonical
  template block **`#### 12f: Hub template`** containing discover's current five-part
  template verbatim (Project Identity, Quick Reference, Architecture at a Glance,
  Documentation links, Conventions), with its "For the full architecture index, see
  [ARCHITECTURE.md](ARCHITECTURE.md)" line made conditional on that file existing at
  write time. Three current sites change, not one:
  1. **Step 1 "Orphan mode hub generation" is deleted** — it is a second creation
     path with its own divergent three-item template. Orphan mode routes to Step 12
     instead (12c's "Does not exist" row). **Input gap closed:** in orphan mode Step 2
     never ran, so Step 12 has read neither README nor build files — the 12c creation
     path therefore reads the repo README and root build file for project identity
     before instantiating 12f (bounded: those two reads only).
  2. Step 12b and 12c's references to "the discover skill's hub template" become
     references to 12f.
  3. **Step 12e option 1** also says "using the discover skill's hub template" — same
     replacement.
- **Seed-run flow made explicit:** after Step 2d (discover returns), the seed run
  **continues to Steps 10–13** (STATUS.md fallback, session state, hub management,
  summary). **Step 2d's "Stubs created. Run `/codebase-scribe` again…" message is
  deleted; Step 13's next-action line is the single authoritative message** (today
  both would print, and 2d's terminal-sounding wording is what made the seed flow
  ambiguous).
- **Documentation-heading match (M10), one rule applied uniformly:** prefer an exact
  `## Documentation` heading when one exists; otherwise the first `##` heading
  containing "Documentation" (case-insensitive); create `## Documentation` only when
  neither exists. Applies to **12d (both variants), 12d's create-if-missing branch,
  and 12e option 2**. The `append-only` marker is placed directly above the matched
  heading. Residual risk, accepted: containing-match can select an unintended section
  (e.g. `## API Documentation`) in hubs with several Documentation-like headings; the
  exact-match preference and first-in-document-order rule bound this.
- **Stale-content refresh (P7):** full-management mode removes lines that exactly
  match the known legacy footer strings — **both observed variants:** `Run
  /codebase-scribe again to draft content for these stubs` and `Run /codebase-scribe
  again to draft content for the stubs` (each with or without backticks around the
  command) — and only when no stub topics remain. Evidence for the strings is field
  data (the kiali hub); the removal list is exact-match only, so user prose cannot be
  caught.
- **docs_dir threading (companion to §1's hook change):** all remaining hardcoded
  `docs/agents` references in behavioral instructions are replaced by "the configured
  docs_dir (default `docs/agents`)": command Steps 3 and 10; draft's claims path,
  STATUS.md regeneration, README-generation links; maintain's claims path, STATUS.md,
  standard-files link checks. (Step 12's link matching already reads "the configured
  `docs_dir` value" and needs no change.) The command resolves `docs_dir` once in
  Phase 0 and passes it in every skill brief. **`branch-local` precedence:** Step 0's
  `branch-local` override (`.scribe/branch-docs/`) wins over `output.docs_dir` for the
  run — the Phase 0 resolution applies the override, and Step 3's docs_dir-mismatch
  warning is suppressed under `branch-local` (it would fire spuriously against the
  override). README prose keeps `docs/agents/` as the documented default. Step 3's
  mismatch warning otherwise survives as a genuine misconfiguration signal.

**Acceptance:** a seed run with custom `output.docs_dir` puts stubs and STATUS.md
there, and subsequent draft/maintain runs read topics, write claims, and regenerate
STATUS.md in that same directory with no mismatch warning (the threading enumeration
is illustrative — the catch-all sentence is authoritative, and also covers draft's
ARCHITECTURE.md generation links, discover's HARD RULE 2 path constraint, and the
merged review agent's cross-topic check); a fresh seed run leaves an AGENTS.md on
disk created by Step 12 during that run (unless `agents_md_policy: none`), and prints
exactly one "run again" message; deleting AGENTS.md while keeping the docs dir routes
through Step 12 with project identity read from the README, not a Step 1 template;
grep finds no "discover skill's hub template" reference anywhere; a hub whose only
section is `## Architecture Documentation` gets links appended into that section by
both 12d and 12e paths (no duplicate created, marker above that heading); a
scribe-managed hub with either legacy stubs-footer variant and no remaining stubs has
exactly that line removed.

## §6. Standard Files and the #39 strip — finding D5

- **Strip** (org-specific, Red Hat directive content), complete list: draft Step A's
  upstream-detection block AND its `docs/upstream.md` classification rules; Step B's
  upstream question text and its entry in the prompt-order line; the `docs/upstream.md`
  template in Step C; the upstream link rule in ARCHITECTURE.md generation; the
  `docs/upstream.md` mention in command Step 13's summary line.
- **Implemented as one isolated, cleanly revertible commit** touching only this
  content. **Ordering constraint:** the strip commit lands **before** P2's rework of
  Step B — both touch the same prompt loop, and reverting a strip that landed after
  the batching would re-add a sequential prompt into a multiSelect flow. A future
  origin-bound revert therefore re-adds upstream as one more multiSelect option, and
  the revert note in the commit message says so.
- **Eval fixtures:** `skills/scribe-draft/eval/cases/case-004-operator-audience/`
  matches an `upstream` grep, but those hits are a reverse-proxy fixture's
  `UPSTREAM_URL` env var and "upstream pool" prose — unrelated to `docs/upstream.md`,
  legitimate for that fixture, and not removed by wave 6 regeneration. The strip's
  acceptance criterion is therefore **permanently** scoped to behavioral files
  (command, skills, hooks, README); eval fixtures are excluded from the upstream grep.
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
one-question rule is conditional; `questions` and `default_branch` appear in the
Error Handling defaults list and README config block (with the Human Input caveat);
the suppression list above is stated in the draft skill.

## §8. Removals — finding M5

All autonomous-mode machinery is deleted:

- Step 0's "Autonomous detection" paragraph, **and Step 0's heading is renamed from
  "Branching strategy and autonomy detection" to "Branching strategy"**.
- Step 9d's autonomous clause. The replacement text is quoted to remove ambiguity —
  the surviving check must stay: "Then check whether the human gate (9e) should fire:
  **if the change is `new_draft` or `major_rewrite`, proceed to 9e before
  finalizing.**" (Deleting the whole sentence would leave 9e's surviving condition
  with no caller and silently disable the human gate.)
- Step 9e trigger condition #1 and its repeated detection paragraph — plus the
  dependent renumbering: 9e's conditions renumber to 1 (new_draft/major_rewrite) and
  2 (rework cap exhausted); the Precedence paragraph and the two option-set headings
  ("For cases 1-2 (change size or autonomy)", "For case 3 (rework cap exhausted)")
  are rewritten against the new numbering; README's "or autonomous runs" phrase is
  removed.

**Acceptance:** `grep -riE 'autonom(ous|y)' plugins/codebase-scribe` returns nothing
(excluding eval fixtures until wave 6), and the 9e case numbering is internally
self-consistent (no reference to a case number that no longer exists).

## §9. Delivery

- **Branch:** all work on `scribe-improvements` (fork), PR'd to fork main in wave
  order.
- **Wave order:**
  1. §2 (default-branch detection + threading, scan validation incl. shallow-clone
     gate + freshness persistence + session guard, watch-path repair, Step 5 row
     rewrites, branch gate incl. all skill-side writers) + §1 (contract + stub-row
     unification + hook) + the cross-cutting frontmatter-preservation rule — the
     kiali-blocking wave.
  2. §5 (discover/hub untangle, 12f template, orphan-mode collapse, heading match,
     docs_dir threading + branch-local precedence, seed-flow fix) + §4's orchestrator
     gitignore seeding (moved up so §3's snapshots never land untracked).
  3. §3 (review agent + brief contract + M2 reduction + snapshots), gated by the
     Cursor agent-dispatch pre-check, **including the eval-tree relocation**
     (`git mv skills/scribe-review/eval* → evals/scribe-review/` with `dataset.path`
     updated) so wave 3's own acceptance criterion passes and no wave ships a
     dangling `skill:` reference. The relocated suite is *stale but present* until
     wave 6 regenerates it — acceptable, since evals run manually post-acceptance.
  4. §4 remainder (decisions/provenance lifecycle, incorporation fallback,
     question-pass contract, Step 3 field extraction, kiali claims migration).
  5. §6 (strip commit first, then P2), §7, §8, P4/P5 polish.
  6. **Evals:** regenerate eval cases/schemas for discover, draft, maintain against
     the final contracts, and regenerate the relocated scribe-review suite —
     **including `eval.md`** (the suite's analysis doc, part of the relocation in
     wave 3). The `skill: codebase-scribe:scribe-review` key is updated to address
     the agent — exact runner syntax for agent-dispatch is verified against the eval
     harness at implementation time. "Keep runner config" **excludes** everything
     that encodes the removed P3 strings: the `recommendation_actionable` judge, the
     `outputs.schema` recommendation lines, `review_quality`'s prompt, and the
     corresponding `eval.md` text — all rewritten for the new recommendation strings.
     Keep model ids (`claude-opus-4-6` — matches the org eval environment). Old
     fixture architecture (`.claude/scribe/inventory.yaml`, `AGENT.md`) fully
     removed.
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
  shape rule, `questions` and `default_branch` config, Human Input caveat, version).
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

- **rev 3 (2026-07-27):** reworked after voting round 1 (fresh voters C and D, both
  NOT_APPROVED; full union of findings applied). Major changes: cross-cutting
  frontmatter-preservation rule (draft §10's enumerated field list would have
  destroyed `decisions:`/`question_passes` on every redraft — the data-loss defect);
  M2 dedup reinstated on corrected evidence (draft/maintain Review Gate sections DO
  restate substeps; both reduced to a pointer); one stub test everywhere (Step 5's
  `<50 words` row rewritten); question-pass incorporation fallback for domain-headed
  topics (append to last section) + full rework-style contract (flag, pipeline,
  NOT-do list, 9f-owned reset); scan shape test scoped to non-null values;
  shallow-clone gate added (skip + warn per Error Handling #4); default-branch and
  branch state threaded into skill briefs; watch-path repair test defined by path
  shape (covers renamed/deleted files); kiali claims migration anchored to Step 1
  with staged-untrack reporting; snapshot semantics corrected (9a reads scan from
  snapshot frontmatter; per-run cleanup; missing-snapshot → major_rewrite); brief
  contract unified (Agent prompt, paths-only, both sides); eval relocation moved into
  wave 3 with eval.md and the full de-P3 carve-out; `current` row made a true
  default; Step 4 session-SHA guard; re-link uniqueness guards; hub template
  canonicalized as 12f with orphan-mode identity reads; 2d message deleted; Step 0
  heading rename + 9d replacement text quoted + `autonom(ous|y)` grep; branch-local
  docs_dir precedence; Error Handling preamble/entry updates; both legacy footer
  variants; assorted enumeration completions (draft :199 fourth site, 9c trailing
  sentence, Rework step 6 writer, STATUS.md writer count, stub-skeleton hook
  enforcement, `agents_md_policy: none` carve-out, `_meta` no-guard note).
- **rev 2.3 (2026-07-27):** closes the three wording-level residuals from the second
  fix-verification round: mechanical watch-path repair rule; root-file carve-out in
  the acceptance line; maintain §9 parenthetical retargeted to `escalated`.
- **rev 2.2 (2026-07-27):** fixes for reviewer A's fix-verification findings:
  root-file watch-path preservation; flat `default_branch` key; explicit M2 mapping
  (superseded in rev 3); permanent eval-fixture grep exclusion; illustrative-list
  caveat; re-link residual acknowledged.
- **rev 2.1 (2026-07-27):** fixes for reviewer B's fix-verification findings:
  fail-closed default-branch detection; single `undercooked` definition; eval
  relocation out of the agent-discovery path.
- **rev 2 (2026-07-27):** full rework after review round 1 (reviewers A and B, both
  NOT_APPROVED, 73 findings total): default-branch detection replacing hardcoded
  `main`; branch gate extended to `scan` and enforced at the writers; scan validation
  with reachability, shape, null handling, freshness persistence, and guards on
  stored-SHA consumers; one-time watch-path repair; `undercooked` redefinition;
  `files_read` dropped; AGENTS.md creation collapsed (orphan mode deleted); seed flow
  made explicit; heading match unified with exact-match preference; all dispatch
  sites enumerated; Cursor pre-check; snapshot sentinel + gitignore guard; decisions
  tombstones + content-based re-linking; orchestrator-owned gitignore seeding;
  question-pass contradiction resolved; Step 3 extraction extended; strip list
  completed; questions config defined; 9e renumbering; four-file version bump;
  review-eval relocation.
