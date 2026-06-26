# ADR 0001 — Tool wire-translation routes through value objects keyed by `tool_wire_format`

- Status: accepted
- Date: 2026-06-26
- Tags: tools, wire-format, value-objects, engines

## Context

Langertha talks to ~25 engines across several incompatible tool dialects: OpenAI
`chat/completions`, Anthropic `/v1/messages`, Gemini `functionDeclarations`, the OpenAI
Responses API, Ollama's native shape, and the Hermes XML convention for models with no native
tool support. Every dialect differs on three axes: how outbound tool *definitions* are
serialized, how inbound tool *calls* are located and parsed out of a response, and how tool
*results* are wrapped into the next-turn message envelope.

Historically each engine carried its own copies of `format_tools`, `response_tool_calls`,
`extract_tool_call`, `format_tool_results` and `response_text_content`. That meant the same
five per-format behaviours were duplicated and drifted across two dozen engine classes; a fix
to the Anthropic tool-result shape had to be applied in every Anthropic-family engine, and a
new provider meant pasting five more methods.

## Decision

1. **An engine declares exactly one `tool_wire_format`** — the enum `openai` | `anthropic` |
   `gemini` | `ollama` | `responses` | `hermes` (`Langertha::Role::Tools`). Its default follows
   the engine base-class hierarchy (`OpenAIBase` leaves it `openai`, `AnthropicBase` overrides
   to `anthropic`, …), so concrete engines inherit it and carry **no tool-format code of their
   own**. Override `_build_tool_wire_format` to change it.

2. **All wire-translation lives in canonical value objects, dispatched by that one tag:**
   - outbound definitions — `Langertha::Tool->to($fmt)` / `->format_list($fmt, \@mcp_tools)`
   - inbound calls — `Langertha::ToolCall` (`->locate($fmt, $data)` finds the raw structures,
     `->from_fmt($fmt, $hash)` parses one; `->extract($fmt, $data)` is the combined form)
   - result blocks — `Langertha::ToolResult->to($fmt)`

   `Langertha::Role::Tools` holds only the **thin tag-driven orchestration** that calls these
   (`format_tools`, `response_tool_calls`, `extract_tool_call`, `format_tool_results`,
   `response_text_content`). Engines carry none of it.

3. **`hermes` is a `tool_wire_format` value like any other.** Its outbound is system-prompt
   injection and its inbound is `<tool_call>` XML parsing, selected by the same tag; the tag
   names and prompt template come from `Langertha::Role::HermesTools`. It is not a separate
   code path bolted onto the loop — it is one branch of the same dispatch.

## Rationale

A new provider becomes a new tag value plus branches inside the value objects — never new
methods on an engine. A wire-shape fix happens once, in the value object, and every engine of
that format gets it. The engine classes shrink to configuration (which roles, which default
tag), which is the level they should operate at. `CONTEXT.md` fixes the vocabulary for this
seam (`tool_wire_format`, **Tool**, **ToolCall**, **ToolResult**, **Result envelope**,
**Assistant echo**) so the terms stay stable across future refactors.

## Consequences

- Adding a **format** = extend the value objects + the `Role::Tools` branches. Adding an
  **engine** of an existing format = zero tool code, just compose the roles and inherit the tag.
- **Result-envelope arity stays in `Role::Tools::format_tool_results`, not in `ToolResult`.**
  A `ToolResult` serializes exactly one block; the envelope (the **Assistant echo** of the
  prior turn plus N result blocks, where N-per-message differs — OpenAI emits N `role:tool`
  messages, Anthropic/Gemini one message with N blocks) is assembled by the orchestration. This
  split is deliberate: the block formatter knows nothing about the surrounding conversation.
- `Role::HermesTools` keeps the tags/template but is no longer a parallel tool-calling
  subsystem — it is the data behind one tag value.

## Future work

- **Reconcile the two inbound entry points.** `ToolCall->extract($fmt, $data)` is the unified
  locate+parse API, but the loop (`Role::Tools::response_tool_calls` + `extract_tool_call`)
  uses the lower-level `locate` + `from_fmt` split, and the legacy self-sniffing
  `extract($data)` form duplicates the per-format response-walking already in `locate`. Collapse
  to one canonical inbound path so there is a single place the per-format walking lives. Tracked
  on the karr board.
