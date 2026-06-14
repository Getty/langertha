# Langertha — Domain Context

Domain language for Langertha's LLM engine framework. This file records the
canonical terms for the tool-calling wire-translation area, sharpened during
architecture review. It complements `CLAUDE.md` (which describes structure) by
fixing the vocabulary for the value objects and the format seam.

## Language

### Tool wire-translation

**tool_wire_format**:
The single per-engine enum naming which tool dialect an engine speaks —
`openai` | `anthropic` | `gemini` | `ollama` | `responses` | `hermes`. The one
authority from which all per-format tool behaviour (outbound, inbound, results,
final-text) derives.
_Avoid_: "provider format", "tool dialect", "format flag"

**Tool**:
The canonical, immutable tool *definition* (name, description, input_schema).
Owns outbound serialization via `to($fmt)` and inbound construction via
`from_$fmt`.
_Avoid_: "tool spec", "function definition"

**ToolCall**:
The canonical tool *invocation* emitted by a model (name, arguments, id,
synthetic). Owns inbound parsing via `extract($fmt, $data)` (locate + parse) and
serialization via `to($fmt)`.
_Avoid_: "function call", "invocation hash"

**ToolResult**:
The canonical *result* of executing one tool (name, call id, content, isError).
Serializes one result *block* via `to($fmt)`. Does NOT own the surrounding
message envelope.
_Avoid_: "tool output", "tool response"

**ToolChoice**:
The canonical tool-selection *policy* (none/auto/required/named) with per-format
serializers. The existing exemplar of the value-object pattern the others now
follow.
_Avoid_: "tool_choice hash"

**Result envelope**:
The provider-shaped *message structure* wrapping ToolResults for the next turn —
arity differs (OpenAI: N `role:tool` messages; Anthropic/Gemini: one message, N
blocks) and it includes the **assistant echo**. Assembled by thin tag-driven
orchestration, not by ToolResult.
_Avoid_: "tool result message", "result wrapper"

**Assistant echo**:
The re-emission of the prior assistant turn (its text + tool_calls) that must
precede ToolResults so the provider has context. Rebuildable from canonical
ToolCalls + text rather than from raw response data.
_Avoid_: "assistant replay", "history echo"

## Relationships

- An engine declares exactly one **tool_wire_format**; its default follows the
  base-class hierarchy (`OpenAIBase`→`openai`, `AnthropicBase`→`anthropic`, …).
- **tool_wire_format** keys the dispatch into **Tool**, **ToolCall**, and
  **ToolResult** class methods — no per-engine tool methods remain.
- A **ToolResult** serializes to one block; the **Result envelope** assembles N
  blocks plus the **Assistant echo** into provider-shaped messages.
- `hermes` is a **tool_wire_format** value like any other — its outbound is
  prompt-injection and its inbound is `<tool_call>` text parsing, selected by the
  same tag (retiring `Role::HermesTools` as a separate role).

## Example dialogue

> **Dev:** "When Anthropic returns tool calls, which module parses them?"
> **Maintainer:** "`ToolCall->extract('anthropic', $data)` — the engine carries
> no parsing method, just `tool_wire_format => 'anthropic'`. The tag picks the
> locator and `from_anthropic`."
> **Dev:** "And feeding results back?"
> **Maintainer:** "Each result is a **ToolResult**; `to('anthropic')` gives one
> `tool_result` block. The **Result envelope** wraps them into a single
> `role:user` message and prepends the **Assistant echo**."

## Flagged ambiguities

- "format_tools" historically meant *both* the outbound serializer *and* the
  engine seam. Resolved: outbound serialization is **Tool->to($fmt)**; the engine
  no longer has a `format_tools` method.
- "tool call" was used for both the model's emitted invocation and the
  execution result. Resolved: **ToolCall** (emitted) vs **ToolResult** (executed)
  are distinct.
