---
name: scribe-maintain
description: Use when all documentation topics are current or lightly drifted. Detects mechanical and decision drift, auto-fixes broken references, flags stale content for review, validates cross-topic consistency, and recalculates scores. Semantic drift evaluation is handled by the review subagent.
---

# Scribe Maintain — Phase 3

You are running Phase 3 (Maintain) of the codebase-scribe documentation system. Your job is to detect drift between documentation and code, auto-fix mechanical issues, flag major drift and decision drift for review, check cross-topic consistency, and recalculate scores. Semantic drift evaluation is handled by the review subagent (scribe-review).

## Safety Rules

1. **Mechanical drift:** Auto-fix broken file paths and function names. Always produce a summary of what you changed.
2. **Semantic drift:** Maintain does not evaluate semantic drift — that is handled by the review subagent (scribe-review). Maintain only flags major churn for review.
3. **Deletions are always semantic:** If a referenced file or function was deleted, flag it — never silently remove the reference.
4. Never modify AGENTS.md
5. Never delete content from topic files — only update references and frontmatter
6. **Every frontmatter write here is a partial update.** Maintain is an independent frontmatter writer — §3 and §4 add stale flags, §5 demotes them, §8 rewrites scores, §9 sets `completeness: 0` — and each of those changes only the keys its own section names. Every other key present in that topic's frontmatter survives verbatim; never reconstruct frontmatter from the fields this skill happens to have read. draft §10's preservation clause is the canonical list — read it there rather than keeping a second copy.

## Inputs

You receive from the orchestrator:
- List of all topics with their current frontmatter
- Per-topic drift classification — one of the orchestrator's Step 5 categories. Only `current` scopes anything in this skill (§§1–2); every other value behaves identically here
- List of topics with changed watch_paths (from Phase 0's git diff)
- `default_branch`, `branching_strategy`, `current_branch`, `shallow: true|false`, `watch_paths` (the repaired value from Step 3), `docs_dir` (resolved in Phase 0), and per-topic `tier: stub|mature` (the orchestrator's Step 5 maturity test — body emptiness / anchored fence-aware stub marker, never its routing row, which also counts `migration_source`) — use the passed values; never re-detect or re-derive them by eye

Read `.scribe.yml` if it exists for drift sensitivity settings.

## Drift Sensitivity

Map the `drift.sensitivity` setting to thresholds:
- `low`: minor = 20% of watched files changed, major = 50%
- `medium` (default): minor = 10%, major = 30%
- `high`: minor = 5%, major = 15%

## Per-Topic Maintenance

For **every** topic the orchestrator passed, including topics classified completely current. Drift classification scopes §§1–2 and nothing else: §§3–5 run per topic under their own stated conditions, and §§6–13 under theirs. This is load-bearing, not a formality — `All current` (the orchestrator's Step 8 row 9) is the only normal route into this skill, so an outer loop that skipped current topics would make §7's quality checks, §8's score recalculation and §10's STATUS.md regeneration unreachable on every ordinary maintain run.

### 1. Scope the Diff

Skipped entirely for a topic the orchestrator classified `current` — by that classification its watch_paths have not changed since `scan`, so there is no churn to scope, and §2 then has no input to act on for it. §3 still validates that topic's references, which is the same work §2's "watch paths unchanged / references broken" row would have ordered.

If `shallow` is true, skip this step entirely — §2 then has no input to act on.

If `scan_sha` fails the shape/resolution/reachability test (`^[0-9a-f]{7,40}$`, `git cat-file -e`, `git merge-base --is-ancestor`), report full churn without running the diff — this feeds §2's drift table its input.

Otherwise, run: `git diff --stat <scan_sha>..HEAD -- <watch_paths>`

Calculate churn: (files changed / total files in watch_paths) x 100

### 2. Apply Drift Table

Skipped entirely in a shallow clone, and for any topic classified `current` — in both cases §1 provides no churn data to feed it. **Other stored-SHA consumers:** `_meta.<topic>_extracted_at` needs no guard (equality-only; mismatch → re-extract, the safe direction).

| Watch paths changed? | References valid? | Action |
|---|---|---|
| No | Yes | **Skip.** Stable and correct. Zero prompts. |
| No | No | Mechanical drift. Auto-fix if possible, flag deletions. |
| Yes, minor (< minor threshold) | Yes | Light check. Skim the diff summary. Usually no action needed. |
| Yes, minor | No | Mechanical drift. Auto-fix broken references. |
| Yes, major (> major threshold) | Either | Major drift. Flag for review — semantic evaluation handled by review subagent. |

### 3. Reference Validation

For each topic file, extract all file path references and function/type name references. Check:
- **File paths:** Resolve first — the topic file sits in `docs_dir`, so a Markdown link destination (`[text](dest)`, `[label]: dest`) that is not a URL or a bare `#anchor` is relative to the topic file's own directory and resolves as `<docs_dir>/<dest>` with `../` normalized away, while an inline path in backticks or prose is repository-relative. Then does `ls` confirm the resolved path exists? Testing a link destination verbatim from the project root escapes the repo and would have this section auto-fix a correct link.
- **Function names:** Search the bare symbol — `grep -rn "<name>" <watch_paths>` — never a Go-shaped declaration pattern alone; this plugin documents TypeScript, Python, Rust, Java, Ruby, C#, C/C++, Swift and Kotlin repositories as well as Go, and an existing `export function <name>()` matches no `func <name>` pattern. A hit is not yet a valid reference: confirm the name is a *declaration* in that file's own language, by the rule `agents/scribe-review.md`'s Pass 1 check 2 states in full — a file holding only `return loadConfig();` is a call site, and a doc citing a symbol that no longer exists anywhere is still wrong. A name absent from `watch_paths` entirely, **or present only at call sites**, is a broken reference. Both halves matter: a false "missing" has this section auto-fix a working reference, and a false "valid" quietly subtracts from §9's 60% ratio and suppresses an escalation that was due.

For broken references:
- If `shallow` is true, skip the rename check (`git log --diff-filter=R`) — renames are indistinguishable from deletions in a shallow clone. Report the broken reference without a deletion flag (do not assign `reason: "deleted"`); §9's escalation is skipped for these references — renames cannot be distinguished from deletions at this clone depth, so the 60% threshold cannot be evaluated.
- Otherwise, check `git log --diff-filter=R -- <old_path>` to find if the file was renamed
- If renamed: auto-fix the reference in the doc, add a stale flag with `reason: "renamed"` (the reason list below classes it "auto-fixed but flagged", and draft's question-pass mode counts on that flag existing), and note the change in your summary
- If deleted: add a stale flag to frontmatter:

```yaml
stale_flags:
  - id: <section-slug>
    heading: "<section heading>"
    flagged_at_sha: <current HEAD>
    reason: "<short category>"
    detail: "<specific explanation>"
```

Reason categories: `"deleted"` (file/function removed), `"renamed"` (auto-fixed but flagged), `"semantic"` (code behavior changed), `"escalated"` (60%+ broken references, needs full redraft).

### 4. Decision Drift Detection

Skipped entirely in a shallow clone (per Step 3's gate). If a topic's `scan_sha` fails the shape/resolution/reachability test, skip this diff-derived branch for that topic's decision entries rather than flagging them.

For each entry in the topic frontmatter's `decisions:` list with `status: active` (an entry with no `status` is treated as `active`), check whether the entry's `source` file changed since it was recorded:

0. **Base selection (guarded stored-SHA consumer):** the diff base is the entry's `resolved_at` when it is present, passes the shape/resolution/reachability test, AND is a descendant of `scan` (`git merge-base --is-ancestor <scan_sha> <resolved_at>`) — an ancestry test, not a "max" comparison of the two SHAs. Otherwise the base is `scan` (`scan_sha`). If `resolved_at` fails the test, ignore it and diff from `scan` — fail toward re-detection, never away from it.
1. Run `git diff --stat <base>..HEAD -- <source_file>` for each active decision entry.
2. If the source file changed by more than `drift.decision_lines_threshold` lines (default: 5, configurable in `.scribe.yml`), check the diff hunks for key terms from the claim text.
3. If both conditions are met (threshold exceeded AND claim terms appear in diff), the decision may be outdated.

Add a stale flag:

```yaml
stale_flags:
  - id: decision-<claim-id>
    heading: "<section where the claim appears>"
    flagged_at_sha: <current HEAD>
    reason: "decision_drift"
    detail: "Claim '<claim text>' (recorded <date>) may be outdated — <file> changed since it was recorded."
```

**Deduplication:** If multiple active decision entries reference the same changed file within one topic, create ONE stale flag per topic listing all affected claims in the `detail` field.

**Retired decisions are skipped entirely** — decision drift only re-examines `active` entries; a `status: retired` tombstone is never re-flagged.

Report in the summary: "N decision drift flag(s) raised. These will be addressed in the next draft or focus run."

### 5. Stale Flag Lifecycle

Skipped entirely in a shallow clone (per Step 3's gate). If a stale flag's `flagged_at_sha` fails the shape/resolution/reachability test, skip its diff-derived branch — leave the flag active without recalculating commit distance.

For existing stale flags in frontmatter:
- Calculate commit distance: `git rev-list --count <flagged_at_sha>..HEAD`
- Check if watch_paths have changed since the flag was raised: `git diff --stat <flagged_at_sha>..HEAD -- <watch_paths>`
- **Demote to known stale** when: commit distance > `stale_commit_threshold` (default 50) AND watch_paths haven't changed in those commits
- **Keep active** when: watch_paths are still changing (code is actively evolving, stale docs are a real problem)
- Surface active flags to the user: "These sections may be outdated: [list]"

### 6. Cross-Topic Consistency

#### Reference Consistency
When two topic files reference the same file path or function, check they describe it consistently (same purpose, same behavior). Flag inconsistencies.

#### Claim Consistency
Read `.claims.yml` in the configured docs_dir (default `docs/agents`). For each topic:
- Check if the topic has claims in `.claims.yml`. **If a topic has zero claims, extract them now** — this catches topics that were drafted by subagents or in earlier versions that didn't extract claims.
- Check if the topic file's git SHA matches `_meta.<topic>_extracted_at`
- If they differ (topic was updated), re-extract claims for that topic
- If `.claims.yml` is missing, re-extract claims for all topics

Re-extraction: read the topic file content and extract factual claims (up to 15–20, proportional — do not pad small topics) using the five claim types (technology, pattern, data_flow, boundary, constraint).

**When re-extracting claims**, read existing `.claims.yml` first and preserve IDs for claims that match by exact match on `{type, topic}` and first 50 characters of the claim text. Only assign new IDs for genuinely new claims. When assigning new sequential IDs, skip any IDs in `_retired_ids` for that topic and every id named in that topic's frontmatter `decisions:` (both active and retired entries) — unguarded, a reworded decision claim could orphan its id, maintain could hand it to a new claim, and a later re-link would duplicate it. Preserve `provenance` fields from existing claims — do not overwrite user-provided provenance with inferred.

**Re-linking, by content:** for each re-extracted claim that did NOT match an existing claim by the exact-match ID stability rule above (so it would otherwise get a fresh sequential ID and lose provenance), check it against the topic frontmatter's `decisions:` entries with `status: active` (an entry with no `status` is treated as `active`): match on `{type, topic, first-50-chars of claim text}`. On a match, restore the entry's provenance onto the claim (`origin: user`, `context`, `recorded`) and the claim takes the entry's `id` instead of a new sequential one — this recovers reworded claims whose wording changed enough to break the exact-match test above.

Uniqueness, both guards required:
- **Many-to-one** (multiple re-extracted claims match the same active decision entry): only the claim appearing **first in `.claims.yml` document order** binds to that entry; the others are treated as unmatched.
- **One-to-many** (one re-extracted claim matches multiple active decision entries): binds **none** — the claim is treated as unmatched, and the ambiguity is reported — report in the §13 summary.

Residual accepted: a claim reworded enough to also break this content match drops the link fail-safe — it becomes a plain new inferred claim with a fresh ID, with no further fallback. After re-linking, report any `active` frontmatter decisions that matched no re-extracted claim ("unmatched active decisions").

Claims missing a `provenance` field default to `{ origin: inferred }` for all purposes including drift detection.

For existing claims without an `id` field, assign IDs on first read using the `<topic-slug>-<N>` scheme.

**Always run contradiction checking** even if no claims were re-extracted. Compare ALL claims across ALL topics. If two claims from different topics contradict each other, add to the `contradictions` section in `.claims.yml`:
```yaml
contradictions:
  - topic_a: architecture
    claim_a: {id: arch-grpc, claim: "gRPC for internal services"}
    topic_b: patterns
    claim_b: {id: pat-http, claim: "HTTP client wrapper for service calls"}
```

### 7. Quality Checks

Run these on every maintain pass:

**Structural validation:** Flag a missing TL;DR blockquote on any topic. On stub topics — the brief's `tier` is `stub`; equivalently, and the fallback when no `tier` was passed, body is empty or contains a line beginning with the stub placeholder marker (`*Stub — will be populated`) outside fenced code blocks — additionally flag any missing skeleton section (`Key Entry Points`, `Patterns & Conventions`, `Gotchas`, `Dependencies & Context`, `Links`). On mature topics, add an advisory note for a missing `## Links` section. If any are missing, flag for the user (do not auto-add — maintain never adds content).

**Actionability check:** Scan each section. If a section is more than 5 lines of prose with zero code references (file paths, commands, function names), flag it:
> "Section '[heading]' in [topic].md has no concrete code references. Consider enriching it with specific file paths and commands."

**Content length check:** If any topic file exceeds 500 lines (or `content.split_threshold`), propose a split.

**Structural diff:** Compare the repo's top-level directory structure against documented topics. If a significant directory exists that isn't covered by any topic's watch_paths, note it:
> "Directory `pkg/newmodule/` exists but isn't covered by any documentation topic. Consider running `/codebase-scribe` to add a topic for it."

### 8. Recalculate Scores

For each topic:

**Freshness:** In a shallow clone, when `scan_sha` fails the shape/resolution/reachability test, or when the current HEAD cannot be read at all (`git rev-parse HEAD` fails — git unavailable, reachable under `branch-local` and `branch-commit`; draft §8's no-HEAD exclusion), skip this diff-derived recalculation for the topic — leave its `freshness` frontmatter value unchanged rather than recomputed. The third case is not the first two: a full clone with a valid stored `scan` still has no HEAD to diff against without git, and the diff below cannot run. Otherwise: `git diff --stat <scan_sha>..HEAD -- <watch_paths>`. Freshness = (unchanged files / total files in watch_paths) x 100, and hold the prior value when the watch_paths contain no files. Under `branching_strategy: main-only`, when `current_branch` != `default_branch` (from the brief), do not update `freshness` or `scan`.

**Human Input:** (slugs in `human_sections` whose headings exist / total fence-aware `##` sections) x 100, 0 when the topic has zero `##` sections — heading↔slug test per the orchestrator's Step 3 prune / draft §4's slug algorithm; no zero-rule, since maintain never solicits answers. Neither diff-derived — still runs regardless of the guard above.

**Completeness:** List depth-1 subdirectories of each watch_path. Completeness = (directories with at least one file referenced in the doc / total directories) x 100, 0 when the watch_paths have no depth-1 subdirectories. Neither diff-derived — still runs regardless of the guard above.

Update scores in the topic file's frontmatter (Freshness left at its prior value where skipped above).

### 9. Escalation

Subject to §3's shallow-clone exclusion: references that §3 reported without a deletion flag because the clone is shallow are not evaluated against this threshold at all. Do not re-derive that rule here — §3's bullet owns it.

If a section has 60%+ of its referenced files no longer existing, escalate:
> "Section '[heading]' in [topic].md has 60%+ broken references. This section needs a full redraft. Recommend running `/codebase-scribe` again to regenerate it."

To ensure the orchestrator routes this topic to Phase 2 on the next run:
1. Set `completeness: 0` in the topic's frontmatter (paired with the stale flag below, this triggers the `escalated` classification in the orchestrator's Step 5)
2. Add a stale flag with `reason: "escalated"`:
```yaml
stale_flags:
  - id: <topic-slug>
    heading: "# <topic title>"
    flagged_at_sha: <current HEAD>
    reason: "escalated"
    detail: "60%+ broken references in section '[heading]', needs full redraft"
```
3. Update session state with `phase_status: "needs_redraft"` for this topic

### 10. Regenerate STATUS.md

After all maintenance checks, regenerate `STATUS.md` in the configured docs_dir (default `docs/agents`) (full overwrite):
1. Read all topic files' frontmatter for current scores
2. Read `.claims.yml` for claim counts and any contradictions
3. Write STATUS.md with: topic table (Topic, Fresh, Human, Complete, Claims, File), stale flags section, contradictions section, review notes (sourced from frontmatter, when present)

### 11. Standard Files Maintenance

After all topic maintenance is complete, check the three human-facing root files for drift. Run this block once per maintain invocation.

#### A. Check each standard file

For each of `README.md`, `CONTRIBUTING.md`, `ARCHITECTURE.md` at the repo root:

1. Check if the file exists. If it doesn't, note it as missing in the summary — do not create it (creation belongs to draft mode).
2. If it exists, read it.

#### B. Per-file drift checks

**README.md and CONTRIBUTING.md:**

Check for mechanical drift only — do not rewrite prose:
- **Broken links:** For every link to a file in the configured docs_dir (default `docs/agents`), check it resolves. If a linked topic file was renamed, auto-fix the link and note it. If it was deleted, flag it.
- **Stale commands:** For any command shown (build, test, run), check it still appears in the build files (Makefile, package.json, etc.). If a command is no longer present, flag it for human review — do not auto-fix commands since the intent may have changed.
- **Missing topic links:** If new topic files exist in the configured docs_dir (default `docs/agents`) that aren't linked from README.md, note them in the summary as candidates to add.

**ARCHITECTURE.md:**

Since this file is a pure navigation index, maintenance is straightforward:
- For every link to a file in the configured docs_dir (default `docs/agents`) it contains, check it resolves. Auto-fix renamed files, flag deleted ones.
- If new topic files exist in the configured docs_dir (default `docs/agents`) that aren't listed, auto-add them using the topic's blockquote TL;DR as the description.
- If a topic's TL;DR blockquote changed since ARCHITECTURE.md was last written, update the description line.

#### C. Report outcome

Include in the Step 13 summary: which files were checked, what was auto-fixed, and what was flagged for human review.

### 12. Review Gate

**After all maintenance checks, STATUS.md regeneration, and Standard Files Maintenance**: follow Step 9 (Review Orchestration) in `commands/codebase-scribe.md` for every topic modified in this pass — dispatching reviews via the scribe-review agent as Step 9c specifies — and only after it completes for all of them, print the §13 summary and then return to the orchestrator.

### 13. Summary

Print a summary:
- Topics checked: N
- Mechanical fixes applied: [list]
- Major drift flags raised: [list]
- Decision drift flags raised: [list]
- Decision provenance: [unmatched active decisions] / [ambiguous re-link matches]
- Stale flags demoted: [list]
- Contradictions found: [list]
- Quality issues: [list]
- Standard files: [auto-fixes applied] / [flags raised] / [missing files noted]
- Review results: [pass/rework/skipped per topic]
- Suggested next action
