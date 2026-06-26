# ADR 0002 — Engine capabilities derive from the composed role inventory

- Status: accepted
- Date: 2026-06-26
- Tags: tools, capabilities, roles, chat_f

## Context

`chat_f` has to decide, per engine, whether a caller's `tools` / `tool_choice` /
`response_format` request can go to the wire as-is or must be rewritten into a form the
provider actually accepts (see the auto-rewrite matrix in `CLAUDE.md`). That decision needs a
truthful, queryable picture of each engine's capabilities: does it do native tools? named
`tool_choice`? `response_format` JSON-schema? Hermes-only?

Hardcoding a capability list on each of ~25 engines would drift away from what the engine can
really do the moment someone adds or removes a role.

## Decision

1. **`Langertha::Role::Capabilities` derives the flag set from which capability-bearing roles
   the engine composes.** A single `%ROLE_TO_CAPS` map (`Role::Chat` → `chat`, `Role::Tools` →
   `tools_native tool_choice_auto tool_choice_any tool_choice_none tool_choice_named`,
   `Role::HermesTools` → `tools_hermes`, `Role::ResponseFormat` →
   `response_format_json_object response_format_json_schema`, …) is the **single source of
   truth**. `engine_capabilities` scans `$self->does($role)` over that map. The role itself
   needs no knowledge of `engine_capabilities`; adding a capability is a one-file change.

2. **`supports($cap)` is the single query.** It is the only way the rest of the codebase asks
   "can this engine do X" — `chat_f`'s auto-rewrite matrix keys off it.

3. **An engine corrects wire reality only via `around engine_capabilities`** — when the role
   inventory over-promises (e.g. a provider composes `Role::Tools` but only accepts a *string*
   `tool_choice`, never a named object), the engine deletes `tool_choice_named` in an `around`.
   This is the one sanctioned escape hatch; it sits next to the engine, not in the map.

`Role::Capabilities` is composed by `Role::Chat`, so every engine has it.

## Rationale

Capabilities follow composition, so they cannot silently disagree with what the engine is
actually wired to do — if it doesn't compose `Role::Tools`, it can't claim tool flags. The only
two places to look are the central map (what a role grants) and the engine's `around` (where
the wire truth differs from the inventory). A capability flag with no role to back it has
nowhere to live, which forces the corresponding role to exist rather than letting a bare string
flag float.

## Consequences

- Adding a capability = edit `%ROLE_TO_CAPS` once. Adding an engine = compose the right roles
  and, only if the wire disagrees with the inventory, one `around`.
- The auto-rewrite matrix in `chat_f` is downstream of `supports()`; keeping the flags honest
  keeps the rewrites correct. A dishonest flag (claimed but not deliverable) is the failure
  mode to guard against — hence the `around` corrections rather than editing the shared map.
- This registry is the precondition for ADR 0001's tag dispatch to be safe: the loop only
  reaches a value-object branch the engine actually supports.
