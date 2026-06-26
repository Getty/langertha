---
name: langertha-adr
description: "How Langertha records Architecture Decision Records: the house docs/adr/ format, what counts as ADR-worthy in an LLM-engine framework, and the structure-first method for backfilling decisions already baked into the engine/role/value-object mesh."
user-invocable: false
allowed-tools: Read, Grep, Glob, Bash
model: sonnet
---

ADRs capture the **WHY** behind architecturally-significant Langertha decisions, so the
rationale survives refactors, releases and the next person who is tempted to "simplify" a seam
back into the engines. Read the existing `docs/adr/` entries as the canonical examples —
codify the format, do not reinvent it.

## Format

- File: `docs/adr/NNNN-kebab-title.md` — `NNNN` zero-padded 4 digits, monotonic per repo
- H1: `# ADR NNNN — Title` (em-dash)
- Metadata as a bullet list, directly under H1:
  - `- Status: proposed | accepted | superseded | deprecated`
  - `- Date: YYYY-MM-DD`
  - `- Tags: a, b, c` (optional)
- Sections (`##`): `Context` · `Decision` · `Rationale` (optional — may fold into Decision) · `Consequences`
- Optional last section: `## Future work` — drift to reconcile or follow-ups that should not
  block; name the karr ticket and stop. Don't do that work in the ADR.

## What counts as ADR-worthy

Two sorts, **both** count:

1. **Deliberate centralization / seam** — a decision to route many engines through one place:
   the `tool_wire_format` tag and the Tool/ToolCall/ToolResult/ToolChoice value objects; the
   `%ROLE_TO_CAPS` capability registry; `Response.tool_calls` as the single tool-call shape;
   the `chat_f` auto-rewrite matrix; the `TranscriptionBase` split; the Raider history model.
2. **Deliberate keep** — structure a review tempted us to change and we chose **not** to (e.g.
   keeping a per-format branch explicit rather than over-abstracting it).

Architecturally significant = touches the public API, engine/role composition, the tool
wire-translation seam, capabilities, structured-output handling, streaming, async, or the
Raider loop. **Not** ADR-worthy: local style, naming, single-use code.

## Where ADRs come from — backfill, structure first

Langertha is not a fork, so there is no upstream baseline to diff against. Recover decisions
already living in the structure:

1. **Structure first** — walk the `Langertha::` namespaces: what is centralized, what each
   base class / role owns, which seam every engine routes through.
2. **Code is the ground truth** — read the actual dispatch (`Role::Tools`, `Role::Capabilities`,
   the value objects). Public method names matter: cite them exactly.
3. **`CONTEXT.md`** is the distilled vocabulary of the tools-lane discussion — the strongest
   single record of intent for that area. Hold it against the code; where they disagree, that
   drift is a finding (record it, or file a karr reconciliation ticket).
4. **Git history** — the refactor commits and their messages confirm the WHY.
5. To judge significance, load the architecture skill on demand — [[perl-ai-langertha]].

## Two run modes

- **audit-only** — report which significant decisions lack an ADR (a gap list); file gaps as
  karr tickets. Write no files. Good for a gentle first pass and recurring drift checks.
- **audit+write** — the same survey, then write the missing ADRs in the format above.

## Numbering

Per repo, monotonic from `0001`. Read the existing `docs/adr/` for the highest number; never reuse.

## Companion

`CONTEXT.md` is the domain language (ubiquitous terms), not a decision log — ADRs link to it,
they don't restate it. Langertha architecture vocabulary → [[perl-ai-langertha]].
