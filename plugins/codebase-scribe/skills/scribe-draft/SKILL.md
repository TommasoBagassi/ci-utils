---
name: scribe-draft
description: Use when generating or enriching documentation content for approved topics. Reads source code within budgets, generates topic file content with interleaved SME questions, extracts claims, and calculates scores.
---

# Scribe Draft -- Phase 2

You are running Phase 2 (Draft & Enrich) of the codebase-scribe documentation system. Your job is to read source code, generate documentation content for topic files, ask the user about design decisions, and produce high-quality agentic docs.

## Safety Rules

1. Never modify AGENTS.md (except append-only for new topic links -- handled by the command, not this skill)
2. Never delete existing verified content in topic files -- only add to or update inferred sections. Sections listed in `human_sections` may be extended, but their existing prose must be preserved verbatim.
3. Always mark auto-generated sections in frontmatter `inferred_sections`
4. Respect file budgets: 30 files per topic (configurable via `.scribe.yml`)
5. When the session file count approaches 150, warn the user -- do not stop automatically

## Inputs

You receive from the orchestrator:
- List of topics to work on (with their current frontmatter state)
- Whether this is SME/focus mode (and the focus description + confirmed code paths)
- Any user-provided context string
- Current session progress (which topics are done/pending)
- `default_branch`, `branching_strategy`, `current_branch`, `shallow: true|false`, `watch_paths` (the repaired value from Step 3), `docs_dir` (resolved in Phase 0), and per-topic `tier: stub|mature` (the orchestrator's Step 5 maturity test — body emptiness / anchored fence-aware stub marker, never its routing row, which also counts `migration_source`) — use the passed values; never re-detect or re-derive them by eye

Read `.scribe.yml` if it exists for budget and content settings.

## Rework Mode

When the orchestrator passes a rework brief (containing `rework: true`), you operate in **rework mode** — a targeted-edit pipeline that differs from normal drafting.

### Rework Brief Contents

You receive from the orchestrator:
- `rework: true` — the mode flag
- `iteration` — rework iteration count (1 or 2)
- The current topic file content (post-review)
- A list of critical findings (each with: tag, location in doc, evidence, suggestion)
- The source files cited in findings' evidence fields
- `default_branch`, `branching_strategy`, `current_branch`, `shallow: true|false`, `watch_paths` (the repaired value from Step 3), `docs_dir` (resolved in Phase 0), and per-topic `tier: stub|mature` (the orchestrator's Step 5 maturity test — body emptiness / anchored fence-aware stub marker, never its routing row, which also counts `migration_source`) — use the passed values; never re-detect or re-derive them by eye

### Rework Pipeline

When `rework: true` is set, follow this pipeline instead of the normal Per-Topic Workflow:

1. **Parse findings.** Read the critical findings list. For each finding, identify the section and content that needs correction.

2. **Read cited source files.** Read ONLY the source files referenced in findings' evidence fields. Do not read the full watch_paths — rework is scoped to the flagged issues.

3. **Apply targeted edits.** For each critical finding:
   - `MISSING_REF`: Find the correct path (check `git log --diff-filter=R` for renames, `find` for relocated files) and update the reference.
   - `CONTRADICTION`: Read the cited source lines, understand the actual behavior, and rewrite the contradicting statement to match the code.
   - `INCONSISTENCY`: Read both contradicting sections and resolve the contradiction — pick the one that matches source code.
   - `WRONG_FILE`: Find the correct file for the pattern and update the attribution.
   - `DEPRECATED`: Remove or update the reference. If the pattern has a replacement, document the replacement instead.

4. **Preserve unaffected content.** Do NOT rewrite sections that have no findings against them. Change only what the findings require.

5. **Skip all questions.** Do not ask design decision questions (section 6: Design Decision Prompt) or focus mode questions (section 7: Observation-Driven Questioning). Rework is mechanical correction, not enrichment.

6. **Update freshness only.** Set `freshness: 100`. Do NOT recalculate `human_input` or `completeness` — those reflect the original draft, not the rework. Under `branching_strategy: main-only`, when `current_branch` != `default_branch` (from the brief), do not update `freshness` or `scan`. §8's no-HEAD exclusion applies here too: with no readable HEAD, preserve the stored `scan` and `freshness` and report it, rather than stamping a SHA that does not exist. Rework is an independent frontmatter writer and never reaches §10, so §10's preservation clause applies here in full: preserve every other frontmatter key verbatim (§10's preservation list — `decisions`, `question_passes`, `human_sections`, `review_notes`, and any other keys present).

7. **Re-extract claims for changed sections.** Read `.claims.yml`. For sections you modified, re-extract claims using the same ID stability rules as section 11 (Extract Claims). Preserve all claims for sections you did not modify.

8. **Validate output.** Run section 12's checklist (Validate Output) — the two-tier structure check (per §12), TL;DR, scores, claims — **except item 2's `human_input` calculation and item 3's `completeness` calculation: rework preserves both values from the original draft (step 6), so neither is recalculated or overwritten here.** Item 2's `freshness` check still applies.

9. **Save session progress.** Mark topic as `rework_pass_<iteration>` in session.json.

### What Rework Does NOT Do

- Does not read the full watch_paths (only cited files)
- Does not ask design decision or SME questions
- Does not recalculate human_input or completeness scores
- Does not propose splits or structural revisions
- Does not run the wrap-up pass

## Question-Pass Mode

When the orchestrator passes a question-pass brief (containing `question_pass: true`), you operate in **question-pass mode** — a targeted-ask pipeline for topics Step 5 classifies `unverified`, distinct from both normal drafting and Rework Mode.

### Question-Pass Brief Contents

You receive from the orchestrator:
- `question_pass: true` — the mode flag
- The batch of topics to question-pass, each with its current topic file content
- `default_branch`, `branching_strategy`, `current_branch`, `shallow: true|false`, `watch_paths` (the repaired value from Step 3), `docs_dir` (resolved in Phase 0), and per-topic `tier: stub|mature` (the orchestrator's Step 5 maturity test — body emptiness / anchored fence-aware stub marker, never its routing row, which also counts `migration_source`) — use the passed values; never re-detect or re-derive them by eye

### Question-Pass Pipeline

When `question_pass: true` is set, follow this pipeline for each topic in the batch:

1. **Ask the §6 question.** Run section 6 (Design Decision Prompt) — including its fallback question if nothing seems unusual — unless §6's zero-question rule fires.
2. **On an answer:** incorporate it per §6/§7's incorporation-target rule, update `human_sections` (and `inferred_sections` per HARD RULE 4), and recompute `human_input`. Extract the claim and write the `decisions:` frontmatter entry at §11 timing — §6/§7's step records the answer only, never the frontmatter entry itself.
3. **Increment `question_passes` on every question pass over the topic** — answered, skipped, OR when §6's zero-question rule fires and nothing is asked (otherwise a conventional topic where §6 never finds a question would classify `unverified` and invoke a no-op pass forever). Then write the topic file per §10 with the updated counter.
4. Output flows through Step 9 (typically `claim_change`).

A stub's *first draft* asking the §6 question does NOT increment `question_passes` — it tracks question passes only — so the user-visible ask count for a never-answering user is up to **three** (one at draft, two passes); the cap's arithmetic is not two total.

### What Question-Pass Mode Does NOT Do

- Does not read source files
- Does not regenerate existing sections
- Does not ask §5 or §7 questions
- Does not process the Standard Files block
- Does not run HARD RULE 2's 15-20-claim extraction — single-claim extraction only. HARD RULE 1's batch-completion duty DOES still apply: the pass is batched, and disapplying it would strand the rest of the batch as perpetually `unverified`.
- Does not stamp `freshness` or `scan` — a question pass is neither a draft nor a rework; enforced by the question-pass exclusion in §8/§10.
- Does not recalculate `completeness` — the pass reads no source files and regenerates no sections, so nothing that feeds §8's formula can have changed; carry the topic's existing value through unchanged. `human_input` is the one score a question pass does recompute (step 2 above), because an incorporated answer changes `human_sections`.
- Does not clear `stale_flags` — §10's empty-`stale_flags` write applies to full drafts only. An `unverified` topic can legitimately hold a live `reason: "deleted"` / `"renamed"` / `"semantic"` flag (none of those routes to a higher-priority Step 5 row), and erasing it here would drop a broken reference on the floor, against maintain Safety Rule 3. Carry the topic's existing `stale_flags` through unchanged.

### Settling: Draft-Side Reset Fallback

9f normally resets `question_passes` to 0 when a topic is drafted or reworked this run (see 9f's reset rule in `commands/codebase-scribe.md`). Two paths bypass 9f entirely for a topic, so a normal draft or rework pass — never a question pass itself — applies the same reset directly:

- **`review.enabled: false`:** apply at finalization of the full redraft (§10's write).
- **The 9b-skip path:** apply after Step 9 returns, for the topic the user chose to skip review on.

On either path, reset `question_passes` to 0 unless `question_passes == 2` with `human_input == 0` — condition (b) of 9f's reset rule, carried unchanged: a user who declined twice stays settled even across genuine redrafts.

## File Skipping Rules

Skip these files -- never read them, they don't count against your budget:
- **Vendored/dependency directories:** `vendor/`, `node_modules/`, `_output/`, `.build/`, `dist/`, `__pycache__/`
- **Lock files:** `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `go.sum`, `Gemfile.lock`, `poetry.lock`, `Cargo.lock`, `composer.lock`
- **Known boilerplate output:** Files with headers from: `protoc`, `swagger-codegen`, `openapi-generator`, `wire`, `mockgen`, `stringer`, `go generate`, `auto-generated by gRPC`
- **Explicitly machine-maintained:** Files marked `DO NOT EDIT`

**Important:** Files generated by AI coding agents (Claude Code, Copilot, etc.) are NOT skipped -- these are real application code.

## HARD RULES

1. **Process all topics in your batch.** The orchestrator sends you a batch of topics (default: 3 per run). Do not stop after drafting one topic — continue to the next topic in the batch until all are done or the session budget is reached. The orchestrator controls batch size; your job is to draft every topic you receive. The one exception is a topic whose decision-drift prompt the user skipped: Decision Drift Resolution passes that topic over undrafted, and you continue to the next one in the batch.

2. **ALWAYS extract claims.** Immediately after writing each topic file, extract claims (up to 15–20, proportional — do not pad small topics) and append to `.claims.yml`. Do this per-topic, not as a batch step. Every drafted topic must have claims.

3. **Propose splits for long topics.** If a topic exceeds 500 lines (or `content.split_threshold`), tell the user: "This topic is [N] lines. I recommend splitting into [topic-overview.md] and [topic-detail.md]. Proceed?" Do not silently generate files over 500 lines.

4. **ALWAYS update `human_sections` and `inferred_sections` when incorporating user answers.** When a user answers a design decision question and you incorporate their answer into a section, you MUST add that section's top-level slug (e.g., `dependencies--context` or `gotchas`) to the `human_sections` list in frontmatter — the scoring list — AND remove it from the `inferred_sections` list, for that list's other consumers. Do NOT add or remove subsection slugs — only the top-level parent. `human_sections` is a set: adding an already-present slug is a no-op — repeat credits are the common case and must not inflate the score. Skipping this step means the section's human attribution is never recorded.

## Decision Drift Resolution

If the orchestrator flags a topic with `decision_drift` stale flags, present each flagged decision to the user before drafting:

> "A previous decision was flagged: '[claim]'. The code has changed since ([file] modified). Is this decision still valid?"

Options via AskUserQuestion:
1. "Still valid — refresh the recorded date"
2. "No longer relevant — retire this decision"

The user can also choose "Other" to provide updated reasoning.

Each outcome below writes the topic frontmatter's `decisions:` entry **first**, then `.claims.yml`, then (where applicable) the topic file content and the stale flag. Every outcome stamps `resolved_at: <current HEAD>` on the frontmatter decision entry — this is what lets maintain §4 stop re-flagging a decision the user has already resolved. A stale flag raised by an earlier git-available run survives in frontmatter, so this section is reachable when HEAD cannot be read (§8's no-HEAD exclusion): there, write no `resolved_at` at all rather than inventing one — maintain §4's base selection already falls back to `scan` for an entry without it, which fails toward re-detection. Every other write in each outcome still applies, the stale-flag removal included.

For option 1 ("Still valid"): update the frontmatter decision entry's `recorded` date and stamp `resolved_at: <current HEAD>`; then update the claim's `provenance.recorded` date in `.claims.yml` to match; remove the stale flag.
For "Other" (updated reasoning): update the frontmatter decision entry's `context` and `recorded`, and stamp `resolved_at: <current HEAD>`; then update the claim's `context` and `recorded` in `.claims.yml` to match, update the topic file content, and remove the stale flag. The updated reasoning is an incorporated user answer, so HARD RULE 4 applies here exactly as it does at §6/§7: add the receiving section's top-level slug to `human_sections`, remove it from `inferred_sections`, and recompute `human_input` in the same write. Under `questions: false` this is the only remaining path by which `human_input` can rise, which is what the Human-Input pinning note promises.
For option 2 ("No longer relevant"): set the frontmatter decision entry's `status: retired` — a tombstone, skipped by re-linking (maintain §6) and by decision drift detection (maintain §4) — and stamp `resolved_at: <current HEAD>`; then remove the claim from `.claims.yml` (add its ID to `_retired_ids`), remove related content from the topic file — **except prose in a section listed in `human_sections`, which is preserved per Safety Rule 2; there, remove the claim only and leave the section's prose untouched** — and remove the stale flag. The retired tombstone survives on every path, `human_sections` included: it is what reserves the ID against reuse and keeps provenance re-linking away from it, so no outcome of this section ever deletes a `decisions:` entry. Because no path here deletes credited human prose, `human_sections` is not pruned and `human_input` is not recomputed by this outcome.

**If the user skips a prompt** — dismisses it without choosing an option and without providing "Other" text — **that flag stays exactly as it is: do not remove it, do not edit it, do not stamp anything on its decision entry.** A skip is "ask me again", never "this is resolved". Concretely, when any of a topic's decision-drift prompts is skipped:

- **Do not draft that topic this run.** Leave the Per-Topic Workflow for it entirely — §8's scores, §10's write (including its empty-`stale_flags` write), §11's claims and §12's checklist all belong to a draft that does not happen, so none of them run and the topic file's `scan` and `freshness` keep their stored values. This is the one exception to HARD RULE 1: move on to the next topic in the batch rather than stopping, but do not draft this one.
- **Outcomes already recorded for that topic's other flags stand.** If the user resolved flag A and skipped flag B, A's writes (its `decisions:` entry, `.claims.yml`, topic content, and the removal of A's stale flag) are complete and correct; none of them stamps `scan` or `freshness`, so skipping the draft costs them nothing. B's flag survives, so the topic still classifies `decision_drift` at Step 5 next run and only B is re-asked.
- **Record it as pending, not complete.** At §13, write the topic's `phase_status` as `pending` in session.json, and report it in the orchestrator's Step 13 summary: the topic was not drafted because a decision-drift prompt was left unanswered, and it will be asked again on the next run.

After resolving all of a topic's flags, proceed with the Per-Topic Workflow for it.

## Per-Topic Workflow

Process ALL pending topics sequentially. Do not stop after one. For each topic:

### 1. Identify Relevant Files

Using the topic's `watch_paths` from frontmatter:
- List all source files in those paths (excluding skipped files)
- Prioritize: entry points first -> files with most cross-references -> most recently changed
- Select up to 30 files (or `budgets.files_per_topic` from config)
- **Minimum read requirement:** Read at least 8 source files per topic, or ALL files if fewer than 8 exist in the watch_paths. Even when migration content is available, the actual source files are the ground truth — migration content tells you what humans thought was important, but code may have changed.

Track the running total of files read this session (update `total_files_read` in session.json after each topic). When approaching 150 (or `budgets.files_per_session`), warn the user:

> "I've read [N] files so far this session across [M] topics. [K] topics remain. Continue?"

**Multiple focus areas:** If the orchestrator passed multiple focus areas, each area gets its own independent file budget of 30 files. Track each area's count separately. Files read for a previous focus area are available as context (don't re-read them) but do NOT count against the current area's budget. The session budget (150) is the outer soft limit across all areas combined.

### 2. Read and Analyze Code

Read each selected file fully. For files over 500 lines, build an index of exported symbols and their doc comments first -- ensure the generated docs reference specific functions and types rather than vague descriptions.

Also read:
- Any existing documentation that covers this topic area (READMEs, guides, existing CLAUDE.md sections)
- The existing topic file content (if enriching, not seeding)

### 3. Generate Topic File Content

**When updating a drifted topic (not a stub):** You are rewriting sections to match current code — not writing a changelog. Read the diff to understand *what changed*, then write the section as a description of the current state. Do not carry the diff frame into the output. A reader of the finished doc should have no idea whether a section was written fresh or updated.

**Handling migrated topics:** If the topic's frontmatter contains `migration_source` and `migration_sections`, this topic has reference content from an existing AGENTS.md that was preserved during migration:

1. Read the file specified by `migration_source` (e.g., `AGENTS.md` — the original file, untouched by discover)
2. Find and read the sections listed in `migration_sections`
3. Use this human-written content as **context alongside your code analysis** — it tells you what the humans considered important about this area
4. **Do NOT count the migration_source file against the file budget.** The migration file is context, not a substitute for reading actual source code. You must still read at least 8 source files from the topic's watch_paths.
5. **Independently verify migration claims.** For each concrete reference in the migration content (file paths, function names, commands, technology choices), verify it against the current codebase. Migration content may be stale — flag anything that doesn't match current code:
   > "Migration content references [X] but the current code shows [Y]. Using current code."
6. Write the topic file per the tier rules below — the 5-section skeleton when the brief's `tier` is `stub`, the existing heading set preserved when it is `mature` — integrating verified migration knowledge with code-based findings
7. After writing, **remove `migration_source` and `migration_sections` from the frontmatter** — they've been consumed
8. After drafting, compare the total content from the referenced migration sections against what you wrote. If >20% of the original content by line count wasn't incorporated, flag it: "Some content from the original AGENTS.md was not incorporated into this topic. Review the original at `[migration_source value]` — sections: [list]."

**Redraft vs. stub draft:** when the brief's `tier` is `mature`, draft preserves the existing top-level heading set and rewrites section bodies in place — except that sections listed in `human_sections` may be extended, but their existing prose must be preserved verbatim (Safety Rule 2) — adding a TL;DR and a `## Links` section only if absent; the 5-section skeleton applies to stub drafts only.

When the brief's `tier` is `stub`, write the topic file following this structure:

```markdown
# [Topic Name]

> [Relevance routing -- 1-2 sentences: what this doc covers and what it doesn't.
> Direct agents elsewhere if this isn't what they need.]

## Key Entry Points
- [file path]: [what it does]
- [command]: [what it does]
- [config file]: [what it configures]

## Patterns & Conventions
[What to follow when writing new code in this area.
Reference specific files, functions, patterns found in the code.
Be concrete: "error handling wraps with fmt.Errorf in pkg/business/"
not "the project uses standard error handling."]

## Gotchas
[What will bite you if you don't know. Things like:
- Implicit ordering dependencies
- Environment variables that must be set
- Files that must not be modified
- Common mistakes and how to avoid them]

## Dependencies & Context
[Deeper understanding: frameworks, design choices, history.
Why things are the way they are, what constraints exist,
what alternatives were considered.]

## Links
- [Related topic file](other-topic.md) -- [why it's relevant]
- [External doc](URL) -- [what it covers]
- [Source file](path) -- [key file for this area]
```

**Content standards:**
- **Every topic MUST start with a blockquote TL;DR** for relevance routing. This is not optional. Example: `> This doc covers the Go backend architecture. For frontend React architecture, see [frontend-architecture.md](frontend-architecture.md).`
- **Content the draft generates for a stub MUST have exactly these 5 sections** (Key Entry Points, Patterns & Conventions, Gotchas, Dependencies & Context, Links) — a floor and a ceiling, matching §12's structure check. If a section has nothing to say, write one line explaining why (e.g., "No known gotchas for this area yet.") rather than omitting the section.
- **Concrete over abstract.** Reference actual file paths, function names, commands. "The cache is populated by informers in `NewKubeCache` in `cache/kube_cache.go`" not "the cache uses an informer-based approach."
- **Citations: `symbol in file`, never bare line numbers.** Cite a function, type, or symbol name plus the file it lives in — e.g. "`NewKubeCache` in `cache/kube_cache.go`" — never a bare line reference like `kube_cache.go:142`. Line numbers drift as code changes; symbol names are stable anchors.
- **Volatile inventories: describe where they live; never enumerate.** For content that changes often (registered routes, CLI flags, config keys, and the like), point to where the current list lives rather than reproducing it in the doc — unless review mechanically re-verifies the enumeration every run.
- **Present state only — no changelog language.** Write what the code *is*, never what it *was* or *changed to*. Forbidden phrases: "was updated", "now supports", "was added", "formerly", "previously", "changed from X to Y", "gained a", "was renamed", "is now". If you are updating a section because the code changed, rewrite the section to describe the current state as if it had always been that way. The git history is the changelog; this doc is not.
- **Target 200-400 lines.** If content exceeds 500 lines (or `content.split_threshold`), propose a split to the user.
- **Over 800 lines:** Hard split -- propose splitting into overview + deep-dive subtopics.

### 4. Track Inferred Sections

Every section you generate gets added to `inferred_sections` in frontmatter, **except a top-level section whose slug is currently in `human_sections`**: regenerating or extending that section's body does not revoke the human credit, so leave its slug out of `inferred_sections` — re-adding it would undo the removal HARD RULE 4 performed. The exception covers that top-level entry only; subsection entries beneath it are added normally, matching HARD RULE 4, which moves the top-level parent alone. There is no case that re-adds a credited top-level slug. Replacing a credited section's human-provided content is a Safety Rule 2 violation, never a branch: if a write is found to have replaced it, restore the prior prose and leave `human_sections` as it was. Do not normalize the violation by stripping the credit — attribution follows the prose, and adjusting it afterwards would launder the deletion of tribal knowledge into tidy bookkeeping. Incorporating a *new* user answer into the section is governed by HARD RULE 4, not by this exception. Use slugs scoped by parent heading.

**Slug algorithm (GitHub-flavored markdown slugging):**
1. Convert heading text to lowercase
2. Remove all characters except letters, numbers, spaces, and hyphens
3. Replace spaces with hyphens
4. For subsections, prefix with parent heading slug and `/`: `parent-slug/child-slug`

Examples:
- `## Key Entry Points` -> `key-entry-points`
- `## Patterns & Conventions` -> `patterns--conventions`
- `### Error Handling` (under `## Patterns & Conventions`) -> `patterns--conventions/error-handling`
- `## Gotchas` -> `gotchas`

```yaml
inferred_sections:
  - id: key-entry-points
    heading: "## Key Entry Points"
  - id: patterns--conventions/error-handling
    heading: "### Error Handling"
  - id: gotchas
    heading: "## Gotchas"
```

### 5. Critical Gap Check (Interleaved Questions)

**Skipped entirely when `questions: false`** in `.scribe.yml` (default `true`).

After drafting each topic, check: are there gaps where the answer would materially change content in OTHER topic files?

**Critical gap** = the answer affects multiple topics. Ask now (1-2 questions max):
> "While documenting [area], I found [observation]. This affects how I document [other topics]. Can you clarify: [specific question]?"

**Non-critical gap** = the answer only affects this one topic. Queue it for the wrap-up pass.

### 6. Design Decision Prompt

**Skipped entirely when `questions: false`** in `.scribe.yml` (default `true`).

**Ask exactly one question per topic, unless the zero-question rule below applies.** Scan the content you just drafted and identify the most significant architectural choice — the one where the "why" is least obvious from the code alone.

**Fallback if nothing seems unusual:** ask about the most significant technology or dependency choice in the topic. Most topics have at least one technology choice worth asking about ("Why gorilla/mux over chi?", "Why zerolog over zap?", "Why controller-runtime over client-go directly?").

**Zero-question rule:** if even the fallback turns up nothing but a conventional choice — a standard pattern, an obvious language idiom, a routine dependency pick, nothing an engineer would find surprising — ask nothing and skip this step for the topic. Do not force a question onto a topic where only a conventional-choice fallback remains.

Otherwise, ask ONE question via AskUserQuestion:

Question: "While documenting [topic], I noticed [specific observation]. Why this approach?"
Options:
1. "No special reason / convention"
2. "I'll explain later in focus mode"

The user can select an option or choose "Other" to provide a free-text explanation.

**If the user provides an explanation:** incorporate the answer, appending to `Dependencies & Context` or `Gotchas`; if neither exists, the last `##` section; if no `##` section exists, create `## Dependencies & Context` and append there. Per HARD RULE #4, update `human_sections` and `inferred_sections` for the section that received the answer. This step records the answer only — the `decisions:` frontmatter entry itself is written at §11, immediately after the claim below is extracted and assigned its id, never here. When extracting claims in Step 11, create a claim with provenance:

```yaml
provenance:
  origin: user
  context: "<the user's answer>"
  recorded: "<today's date>"
```

**If the user skips:** move on, no friction.

**Heuristic — what to ask about:**
- Choices: "Why a pure-Go SQLite driver instead of CGO?"
- Constraints: "Why 15-minute client expiration, not configurable?"
- Boundaries: "Why no RBAC in the cache layer?"
- Absences: "Why no retry logic here?"

**Do NOT ask about:** standard patterns, conventional dependency choices, obvious language idioms.

**Note:** this first-draft question does not increment `question_passes` — that counter tracks Question-Pass Mode passes only, never the draft-time ask. The user-visible ask ceiling for a topic whose user never answers is three: this draft-time ask, plus up to two question passes.

### 7. Observation-Driven Questioning (Focus Mode)

**Skipped entirely when `questions: false`** in `.scribe.yml` (default `true`).

If in focus/SME mode, identify 3-5 non-obvious patterns in the code you just read for this topic. **HARD RULE: ask them sequentially** via AskUserQuestion — one question at a time, never batched. Do NOT make multiple AskUserQuestion calls in parallel.

**Question types driven by code observations:**
- **Technology choices**: "I see [X] is used here. Why X over [obvious alternative]?"
- **Unusual patterns**: "This [pattern] breaks the convention used in [other area] — intentional?"
- **Constraints**: "This value [X] is hardcoded — what drives it?"
- **Boundaries**: "[Layer A] doesn't enforce [X], leaving it to [Layer B] — by design?"
- **Absences**: "There's no [retry/fallback/cache/test] here — deliberate?"

Each question uses AskUserQuestion with descriptive options. The user can select an option or choose "Other" for a free-text answer.

**Follow-up cap:** maximum 1 follow-up per answered question ("What was tried before?" / "What's fragile about this?"). Then move to the next question.

**Total interaction budget:** at most 10 interactions per topic (5 questions + 5 follow-ups). Users will skip some; typical is 6-8.

**Do NOT ask:** "What does [function] do?" — the code answers that. Ask "why", not "what."

Incorporate answers, appending to `Dependencies & Context` or `Gotchas`; if neither exists, the last `##` section; if no `##` section exists, create `## Dependencies & Context` and append there. Per HARD RULE #4, update `human_sections` and `inferred_sections` for each section that received user input. This step records the answer only — the `decisions:` frontmatter entry itself is written at §11, immediately after the claim below is extracted and assigned its id, never here. When extracting claims in Step 11, create claims from user answers with provenance:

```yaml
provenance:
  origin: user
  context: "<the user's answer>"
  recorded: "<today's date>"
```

### 8. Calculate Scores

For each topic:
These scores are non-negotiable for draft output:
- **Freshness:** always `100` — the content was just generated from current code. Not a judgment call. Under `branching_strategy: main-only`, when `current_branch` != `default_branch` (from the brief), or when this is a question pass (`question_pass: true`), do not update `freshness` or `scan`.

  **No-HEAD exclusion (canonical — every `scan`/`freshness` writer in this skill points here).** Before stamping either field, read the current HEAD (`git rev-parse HEAD`). If it cannot be read, git is unavailable — the only way a `branch-local` or `branch-commit` run gets this far, since `main-only` refuses at Step 0 — and there is no SHA to stamp: preserve the topic's stored `scan` and `freshness` untouched, draft the content normally, and report the topic in the run summary as drafted without a scan stamp. Ask this where the value is needed, by trying to read HEAD; never infer it from `default_branch: null`, which also occurs in git-available repositories with an unresolved remote.
- **Human Input:** calculate as (slugs in `human_sections` whose headings exist / total fence-aware `##` sections) x 100, 0 when the topic has zero `##` sections — heading↔slug test per the orchestrator's Step 3 prune / draft §4's slug algorithm. The formula is universal: an empty `human_sections` list yields 0 with no special-cased zero-rule. If the user provided answers and a slug was added to `human_sections` per HARD RULE #4, the score reflects that immediately.
- **Completeness:** calculate this one. Count depth-1 subdirectories of each watch_path. Completeness = (subdirectories with at least one file referenced in the doc / total subdirectories) x 100, 0 when the watch_paths have no depth-1 subdirectories. When this is a question pass (`question_pass: true`), do not recalculate `completeness` — carry the topic's existing value through (see Question-Pass Mode's NOT-done list).

### 10. Write Topic File

Write the complete topic file with:
- YAML frontmatter (scan SHA = current HEAD — only on the default branch under `main-only`, not a question pass, and only when HEAD can be read at all, per §8's no-HEAD exclusion, scores, inferred_sections, watch_paths (the repaired value from the brief — never narrowed by draft), empty stale_flags (full drafts only — a question pass carries the topic's existing `stale_flags` through unchanged, per Question-Pass Mode's NOT-done list), and preserved verbatim (except where a rule in this skill names them as a writer — see HARD RULE 4 for `human_sections`): `decisions`, `question_passes`, `human_sections`, `review_notes`, and any other keys present)
- Markdown content following the structure above

If `review.enabled: false` **and this write is a full draft — never a question pass**, also reset `question_passes` here per Question-Pass Mode → Settling: Draft-Side Reset Fallback. A question pass reaches §10 too (its step 3 writes the file with the incremented counter); resetting here would undo that increment and re-open the same question forever.

### 11. Extract Claims

Immediately after writing the topic file, extract factual claims (up to 15–20, proportional — do not pad small topics) from the content you just wrote. Do this while the content is fresh in context — do NOT defer to a batch step later.

**Claim ID scheme:** `<topic-slug>-<sequential-number>` (e.g., `backend-architecture-1`, `graph-engine-3`). IDs increment forever — never reuse a retired ID.

**ID stability:** Before extracting, read existing `.claims.yml` if it exists. Match new claims to existing ones by exact match on `{type, topic}` and first 50 characters of the claim text. Matched claims keep their existing ID. Only genuinely new claims get the next sequential ID for that topic. When assigning new sequential IDs, skip any IDs in `_retired_ids` for that topic **and every id named in that topic's frontmatter `decisions:` (both active and retired entries)**. For existing claims without an `id` field, assign IDs on first read.

Use only these five types:

| Type | What to extract |
|------|----------------|
| `technology` | Named technology/framework/library choices |
| `pattern` | Architectural or code patterns |
| `data_flow` | How data moves between components |
| `boundary` | System boundaries and ownership |
| `constraint` | Rules, invariants, requirements |

**Provenance:** Every claim gets a `provenance` field using block YAML structure (never inline):

```yaml
claims:
  - id: backend-architecture-1
    type: technology
    topic: backend-architecture
    claim: "HTTP routing uses gorilla/mux"
    source: "routing/routes.go"
    provenance:
      origin: inferred

  - id: backend-architecture-12
    type: technology
    topic: backend-architecture
    claim: "PostgreSQL chosen over MongoDB for ACID support"
    source: "internal/store/postgres.go"
    provenance:
      origin: user
      context: "MongoDB rejected for lack of ACID; SQLite rejected for no vector search"
      recorded: "2026-05-04"
```

- Code-inferred claims: `origin: inferred` (no `context` or `recorded`)
- Claims from user answers (Steps 6 or 7): `origin: user`, `context` captures the reasoning, `recorded` is the date
- Claims missing `provenance` default to `origin: inferred` for all purposes

**Write the `decisions:` entry:** immediately after a claim with `provenance.origin: user` is extracted and assigned its id, write (or update) the corresponding entry — the entry whose `id` equals the claim's id; a `status: retired` entry is never updated or reactivated — in the topic frontmatter's `decisions:` list — this is where the entry is written; §6/§7 only record the answer, never the frontmatter entry itself.

```yaml
decisions:
  - id: backend-architecture-12
    type: technology
    claim: "PostgreSQL chosen over MongoDB for ACID support"
    context: "MongoDB rejected for lack of ACID; SQLite rejected for no vector search"
    recorded: "2026-05-04"
    source: "internal/store/postgres.go"
    status: active
```

The entry's `id`, `type`, `claim`, and `source` mirror the claim's; `context` and `recorded` mirror `provenance.context` and `provenance.recorded`; `status` is `active` at write time.

When a claim is deleted (e.g., decision drift resolution), add its ID to a `_retired_ids` list in `.claims.yml` to prevent reuse. When assigning new sequential IDs, always skip any IDs in `_retired_ids` for that topic and every id named in that topic's frontmatter `decisions:` (active and retired).

Append claims to `.claims.yml` in the configured docs_dir (default `docs/agents`). Include `_meta` with the topic's current git SHA as `<topic>_extracted_at`.

### 12. Validate Output

After writing each topic and extracting claims, run this checklist:
- [ ] Structure check (two-tier), branched on the brief's `tier` — what the topic was **at the start of this draft** — never on what it is now — §10 has already written the file by the time you run this checklist, so a just-drafted stub no longer carries its marker and would take the mature branch, silently skipping the very Content standard the 5-section rule exists to enforce: topics that entered this draft as stubs have exactly these 5 `##` headings: `Key Entry Points`, `Patterns & Conventions`, `Gotchas`, `Dependencies & Context`, `Links`, plus TL;DR; topics that entered mature have TL;DR, and free-form domain headings are legitimate
- [ ] Frontmatter has `freshness: 100` — except where §8's exclusions apply, where `freshness` is carried through unchanged. **All three, and the list is exhaustive here on purpose:** under `branching_strategy: main-only` when `current_branch` != `default_branch`; when this is a question pass; and when the current HEAD could not be read (§8's no-HEAD exclusion). A checklist that names only the first two reads as a defect on the third and orders the preserved value "fixed" to 100 — re-stamping the freshness the writer had just, correctly, left alone — and `human_input` is calculated as (slugs in `human_sections` whose headings exist / total fence-aware `##` sections) x 100, 0 when the topic has zero `##` sections
- [ ] Completeness is a calculated percentage, not an estimate — carried through unchanged in a question pass, per §8
- [ ] Claims were written to `.claims.yml` for this topic
- [ ] The TL;DR blockquote exists as the first line after the `#` heading
- [ ] If user answered a design decision question, the answer is incorporated and the top-level section slug is added to `human_sections` and removed from `inferred_sections` (HARD RULE #4)

If any check fails, fix it before moving to the next topic.

### 13. Save Session Progress

Update `.scribe/session.json` with this topic's status as `complete` and the count of files read. A topic passed over for an unanswered decision-drift prompt is recorded `pending` instead — it was not drafted, and marking it complete would hide a topic that still needs the user.

## After All Topics

### Wrap-Up Pass

**Skipped entirely when `questions: false`** in `.scribe.yml` (default `true`) — no non-critical questions are ever queued for it in that case, since §5 that queues them is itself skipped.

Present all queued non-critical questions to the user. These are questions where the answer only affects the single topic they belong to. Document answers into the relevant topic files, using the same incorporation target rule as §6/§7. This pass runs *after* §8/§10 have already written the files, so for each answered section: add its top-level slug to `human_sections`, remove it from `inferred_sections`, recompute `human_input`, and rewrite the touched topic's frontmatter — without the recompute, the credit would not land until the next run. That rewrite is a partial update like every other frontmatter write: it changes `human_sections`, `inferred_sections` and `human_input` and nothing else, and §10's preservation clause — the canonical list — governs it in full. This pass reaches the file after §10 rather than through it, so the clause has to be named here.

### Regenerate STATUS.md

After all topics are drafted, regenerate `STATUS.md` in the configured docs_dir (default `docs/agents`) (full overwrite):
1. Read all topic files' frontmatter for current scores
2. Read `.claims.yml` for claim counts and any contradictions
3. Write STATUS.md with: topic table (Topic, Fresh, Human, Complete, Claims, File), stale flags section, contradictions section, review notes (sourced from frontmatter, when present)

### Structure Revision

If during analysis you discover the topic structure was wrong (e.g., a `services/` directory doesn't contain independent services), propose a revision:
> "During analysis I found [observation]. I recommend merging `services.md` into `architecture.md`. Proceed?"

## Standard Files

After all topics are processed and STATUS.md is regenerated, check that the repo's required standard files exist and have substantive content. Run this block once per draft invocation, not per topic.

### Step A: Classify each standard file

For each of `README.md`, `CONTRIBUTING.md`, `ARCHITECTURE.md`, `CLAUDE.md`, `GEMINI.md` at the repo root — AGENTS.md is already managed by the orchestrator, skip it here:

1. Check if the file exists.
2. If it exists, read it and count its lines.
3. Classify using the rules below:

**README.md / CONTRIBUTING.md / ARCHITECTURE.md:**
- **Missing** — file does not exist.
- **Thin** — exists but fewer than 30 lines, OR passes the line threshold but lacks project-specific detail: no commands, no links, no named components — only a title, generic prose, or placeholder text (e.g., "TODO", "Coming soon", a single sentence, boilerplate unchanged from a template).
- **Substantive** — exists with ≥ 30 lines AND contains at least one concrete signal of project-specific content (a command, a link, a named file or component, a real description beyond a single sentence). **Skip entirely — no prompt, no changes.**

**CLAUDE.md / GEMINI.md:**
- **Missing** — file does not exist.
- **Thin** — exists but contains no reference to `AGENTS.md` (empty, just a title, or stale content unrelated to this repo).
- **Substantive** — exists and contains a reference to `AGENTS.md` (the redirect is working). **Skip entirely — no prompt, no changes.**

### Step B: Ask the user which missing or thin files to generate

No AskUserQuestion question may be constructed with fewer than 2 or more than 4 options (verified against the host tool schema). At most five files can qualify (Step A's file set), so handle every count explicitly, in this order: README.md → CONTRIBUTING.md → ARCHITECTURE.md → CLAUDE.md → GEMINI.md.

- **0 qualify** — skip Step B and Step C entirely; there is nothing to ask or generate.
- **1 qualifies** — a multiSelect question is invalid with a single option. Ask one AskUserQuestion with two options instead. Question: `"Generate <filename>?"` Options: `"Yes — generate <filename>"` (description: `"<filename> is [missing / thin, ~N lines]. I'll draft content based on the codebase and context already loaded."`) and `"No — skip <filename>"` (description: "Leave this file as-is.").
- **2–4 qualify** — ask one multiSelect AskUserQuestion listing every qualifying file as an option. Question: `"Which standard files should I generate?"` Options (one per qualifying file): Label `"<filename>"` — description: `"<filename> is [missing / thin, ~N lines]. I'll draft content based on the codebase and context already loaded."`
- **5 qualify** — ask two multiSelect AskUserQuestion calls, split 3 + 2 in the order above (never 4 + 1, which would leave the second question with a single option), each shaped like the 2–4 case for its slice.

For each file the user selects (or approves via "Yes" in the 1-file case), generate and write it (Step C). Unselected files are skipped, left as-is.

### Step C: Generate each selected file

Use only context already in scope — source files read during topic drafting, AGENTS.md, build config files read in Phase 0, and `.claims.yml`. Do **not** read additional source files; stay within the session budget.

**Orphan mode:** AGENTS.md does not yet exist (Step 12 creates it later) — the README and ARCHITECTURE generators below fall back to the repo README for project identity instead.

---

**README.md**

```markdown
# <Project Name>

<1-3 sentence description pulled from AGENTS.md or existing README.>

## Quick Start

<Minimal build/run commands from Makefile, package.json, Cargo.toml, etc. already read.>

## Documentation

<Links to topic files in the resolved docs_dir that exist. Include one-line description per link.>

- [AGENTS.md](AGENTS.md) — quick reference hub for commands and architecture overview

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
```

- Pull project name and description from AGENTS.md identity section, or from a thin existing README.
- Pull commands from build files already read. If none were read, note "See Makefile / package.json for build commands."
- Link to topic files in the resolved docs_dir that exist. Use each topic's blockquote TL;DR as the link description.
- Keep to 30–80 lines.

---

**CONTRIBUTING.md**

```markdown
# Contributing

## Development Setup

<Steps to set up a local dev environment, derived from build files already read.>

## Running Tests

<Test commands from Makefile, package.json, etc.>

## Submitting Changes

1. Fork the repo and create a branch from `main`.
2. Make your changes with tests where applicable.
3. Run tests and ensure they pass.
4. Open a pull request with a clear description of what changed and why.

## Code Style

<Language-specific conventions observed in source files, e.g. gofmt/golangci-lint, eslint/prettier, ruff.>
```

- Extract setup and test commands from build files already read. If a CI config was observed, note it.
- Note any linters or formatters if their config files were visible during source reading.
- Keep to 40–80 lines.

---

**ARCHITECTURE.md**

`ARCHITECTURE.md` is a **thin navigation hub** — it does not duplicate content. All real architecture detail lives in the configured docs_dir (default `docs/agents`).

```markdown
# Architecture

> This file is a navigation index. For detailed documentation, follow the links below.

## Documentation Index

- [<Topic Title>](<docs_dir>/<name>.md) — <TL;DR blockquote from the topic file>
- ...

## Quick Reference

See [AGENTS.md](AGENTS.md) for commands, build instructions, and a directory overview.
```

Rules for ARCHITECTURE.md:
- List topic files that cover architectural concerns: architecture, patterns, data model, API surface, core logic. Skip purely operational topics (build-deploy, testing) unless they have architectural significance.
- Pull each TL;DR from the topic file's blockquote (first line after `#` heading). If the topic is still a stub, use its description instead.
- If no topic files exist yet, create the file with placeholder links (`<docs_dir>/architecture.md`) — they will become valid after drafting completes.
- **Never write prose architecture content in this file.** All substantive content lives in the configured docs_dir (default `docs/agents`).
- Target < 40 lines total.

---

**CLAUDE.md**

```markdown
# Claude Code Instructions

See [AGENTS.md](AGENTS.md) for project identity, architecture overview, build commands, and conventions.

For detailed topic documentation, see [<docs_dir>/](<docs_dir>/).
```

Rules:
- Intentionally minimal — AGENTS.md is the source of truth, no duplication
- Target: 4–6 lines

---

**GEMINI.md**

```markdown
# Gemini Instructions

See [AGENTS.md](AGENTS.md) for project identity, architecture overview, build commands, and conventions.

For detailed topic documentation, see [<docs_dir>/](<docs_dir>/).
```

Rules: identical to CLAUDE.md

### Step D: Record outcome

After Standard Files completes, note which files were created, updated, or skipped. This is reported in the orchestrator's Step 13 summary.

### Review Gate

Skip this section when in rework mode — the orchestrator handles scoped re-review via Step 9d. Otherwise, **after all topics in this batch are drafted, STATUS.md regenerated, and Standard Files processed (skipped entirely in a question pass — see Question-Pass Mode's NOT-done list)**: follow Step 9 (Review Orchestration) in `commands/codebase-scribe.md` for every topic modified in this pass — dispatching reviews via the scribe-review agent as Step 9c specifies — and return to the orchestrator only after it completes for all of them.

For any topic where the user chose 9b-skip, apply the reset in Question-Pass Mode → Settling: Draft-Side Reset Fallback.
