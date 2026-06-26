# Langertha House Rules

Apply to every task in the Langertha distribution unless explicitly overridden. Bias: caution
over speed on non-trivial work; use judgment on trivial tasks.

## Engineering discipline

1. **Think before coding** — State assumptions explicitly. When uncertain, ask rather than
   guess. Present multiple interpretations when ambiguous. Push back when a simpler approach
   exists. Stop when confused; name what's unclear.
2. **Simplicity first** — Minimum code that solves the problem. Nothing speculative. No
   abstractions for single-use code.
3. **Surgical changes** — Touch only what you must. Don't "improve" adjacent code, comments,
   or formatting. Match existing style.
4. **Goal-driven execution** — Define success criteria, loop until verified.
5. **Surface conflicts, don't average them** — Contradicting patterns: pick one (more
   recent / more tested), explain why, flag the other for cleanup. Don't blend.
6. **Read before you write** — Before new code, read exports, immediate callers, shared
   roles. "Looks orthogonal" is dangerous, especially across the engine/role mesh.
7. **Tests verify intent, not just behavior** — Tests encode WHY behavior matters. A test
   that can't fail when business logic changes is wrong.
8. **Checkpoint after every significant step** — Summarize: done / verified / left. Don't
   continue from a state you can't describe back.
9. **Match the codebase's conventions, even if you disagree** — Conformance > taste. Surface
   a harmful convention; don't fork silently.
10. **Fail loud** — "Done" is wrong if anything was skipped silently. "Tests pass" is wrong
    if any were skipped (and most tests in `t/80-86*` skip without live API keys — say so).
    Surface uncertainty, don't hide it.

## Delegation

This rule depends on whether the Agent/Task tool is available to you.

- **You can spawn subagents** (orchestrating main agent): Do NOT touch behavior-relevant
  Langertha code yourself — delegate to `langertha-worker`. Your lane: coordinate, inspect,
  plan, review diffs, run tests, manage git, write/curate ADRs and non-behavioral docs. When
  in doubt, delegate. Why: the `langertha-*` agents get their skills force-loaded via
  `briefing.skills` (perl-ai-langertha, perl-moose, …); the bare main agent gets no briefing
  and would touch the engine/role internals with too little context.
- **You cannot spawn subagents** (you ARE `langertha-worker` or similar): The delegation lock
  does not apply to you — implement, refactor, debug, and test per these rules.

Behavior-relevant = runtime behavior, public API, engine request/response handling, the tool
wire-translation seam (`tool_wire_format` + the Tool/ToolCall/ToolResult/ToolChoice value
objects), the capability registry, the Raider loop, streaming, async, MCP integration, error
handling, tests, performance. Pure prose docs, ADRs, and `Changes` notes are not.

## Coordination — karr board (always in scope)

Ticket coordination is the orchestrating agent's job, so `karr` is always in scope — don't
invoke the `karr` skill first, just use it. Git-native kanban; board state lives in
`refs/karr/*` in this repo (Langertha is a single distribution — one board, no cross-repo
handoff). Day-to-day:

- `karr list --compact` / `karr board` — open work · `karr show ID` — detail
- `karr create "Title" --priority high --tags a,b --body '…'` — new ticket
- `karr edit ID -a "note"` · `--claim NAME` · `--block "why"` — update
- `karr move ID in-progress --claim NAME` — start · `karr handoff ID --claim NAME --note "…"` — to review
- mutating commands auto-sync; `karr sync --pull|--push` for explicit exchange

Use karr to record decisions worth solidifying, drift to reconcile, and follow-up work that
should not block the current change. Full command surface: skill `karr`.

## Public issues (GitHub) — never act without instruction

Two trackers, two universes. **karr** is the AI/agent work board — internal, ours, churned
freely (see above). **GitHub issues** (`gh` CLI, `github.com/Getty/langertha`) are the
**public tracker: real humans' bug reports and feature requests**, outward-facing and written
under the maintainer's account.

Security rule: **never act on a GitHub issue or PR on your own initiative — not even to read
it.** No listing, viewing, commenting, editing, closing, or creating unless the user
explicitly tells you to handle a specific public item. Incoming user tickets are NOT a queue
the agent drains; they are touched only on direct instruction, and every write is confirmed
first because it publishes under the maintainer's name. Full `gh` usage + guardrails: skill
`langertha-github-issues`.

## Release — never without permission

`dzil build` / `dzil test` are fine anytime. `dzil release` and any CPAN upload are STRICTLY
forbidden without the maintainer's explicit go-ahead — even if a plan or TODO lists "release"
as the next step. The `[@Author::GETTY]` bundle bumps `$VERSION` and tags on release; for
anything heading toward release: stop and ask.
