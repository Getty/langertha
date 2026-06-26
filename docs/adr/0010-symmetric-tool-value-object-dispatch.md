# ADR 0010 — One canonical inbound `ToolCall->extract($fmt, $data)` and a symmetric `ToolChoice->to($fmt)` complete the value-object seam

- Status: accepted
- Date: 2026-06-26
- Tags: tools, wire-format, value-objects, tool_choice

## Context

ADR 0001 routed all tool wire-translation through four value objects (`Tool`, `ToolCall`,
`ToolResult`, `ToolChoice`) dispatched by a single per-engine `tool_wire_format` tag. It left
two asymmetries in that seam, flagged as future work:

1. **Two inbound entry points.** `ToolCall->extract` was meant to be the unified locate+parse
   API, but the inbound surface had drifted into three overlapping shapes: the tool-calling
   loop walked responses with the lower-level `locate` + `from_fmt` split; a legacy
   *self-sniffing* `extract($data)` (single-arg) re-implemented per-format response-walking that
   `locate` already owned; and `extract($fmt, $data)` existed but was not the single path. The
   per-format walking thus lived in more than one place — exactly the duplication ADR 0001 set
   out to remove.

2. **One value object missing its sibling's dispatch.** `ToolChoice` was the original exemplar
   of the value-object pattern, yet alone among the four it had no symmetric `to($fmt)`
   entry — only per-format `to_openai` / `to_anthropic` / `to_gemini` / `to_responses`
   serializers that each engine called by name. `Tool`, `ToolCall`, and `ToolResult` already
   exposed `to($fmt)`; `ToolChoice` did not.

Resolved on `main` in commit `d4a0cf6` ("Unify ToolCall inbound on extract($fmt,$data); add
ToolChoice->to($fmt)").

## Decision

1. **One canonical inbound entry: `ToolCall->extract($fmt, $data)`** — strictly
   `locate($fmt, $data)` (find the raw structures) + `from_fmt($fmt, $hash)` (parse one). The
   per-format response-walking lives in exactly one place, `locate`. A fail-loud guard
   (`croak ... if ref $fmt`) kills the legacy single-arg `extract($hashref)` call. Every engine
   `chat_response` path now passes a format into `extract`.

2. **Self-sniffing is demoted and explicitly named.** Shape detection becomes
   `sniff_format($data)` (top-level shape only — it does *not* walk per-format tool structures),
   and `extract_sniff($data)` = `sniff_format` → `extract`. It is deliberately *not* called
   `extract`, so there is exactly one canonical, format-pinned inbound entry. `extract_sniff` is
   used by a single caller — the `Langertha::Output::Tools` back-compat facade, which genuinely
   has no wire format in scope.

3. **`ToolChoice->to($fmt)` is added**, mirroring `Tool` / `ToolCall` / `ToolResult`. All four
   tool value objects now share the symmetric `to($fmt)` outbound dispatch. `%TO_METHOD` maps
   only the wires that carry a wire-level `tool_choice` parameter — `openai` / `anthropic` /
   `gemini` / `responses`. `ollama` and `hermes` croak through `to` (Ollama has no wire-level
   tool_choice; Hermes forces via prompt injection). `to_perplexity` stays a standalone
   helper, off the tag dispatch, because Perplexity's named-tool request is not a
   `tool_wire_format` value — it is rewritten to `response_format` by `chat_f` (ADR 0005).

## Rationale

This closes ADR 0001's symmetry: per direction there is now one place that knows the wire
shape. Adding inbound for a new format = one branch in `locate` + one entry in `%FROM_METHOD`;
adding outbound tool-choice = one branch in `ToolChoice` + one entry in `%TO_METHOD`. Nothing
per-engine, in either direction. The `extract` / `extract_sniff` split makes the rare
no-format-in-scope case loud and singular instead of letting a self-sniffing overload quietly
duplicate the locator.

### The deliberate exception worth preserving: `Role::OpenAICompatible` pins `openai`

`Role::OpenAICompatible` does **not** use `$self->tool_wire_format` for its inbound or its
tool_choice. It pins both to the literal `openai`:

- inbound — `Langertha::ToolCall->extract('openai', $data)` in `chat_response`
- tool_choice — `$tc->to('openai')` in `chat_request`

This is intentional and must **not** be "consistency-fixed" to `$self->tool_wire_format` by a
future refactor. Two independent reasons:

- **The OpenAI-compatible response envelope is always OpenAI-shaped**, even for engines whose
  `tool_wire_format` is `hermes`. A Hermes engine's calls ride inside the message *text* and
  are parsed by the `Role::Tools` hermes branch — never by `chat_response`. So `chat_response`
  must read the OpenAI envelope as OpenAI, regardless of the engine's tool dialect.
- **Perplexity composes no `Role::Tools`** (it deliberately omits it because that path sends a
  `tools` array Perplexity rejects). `tool_wire_format` is an attribute of `Role::Tools`, so
  `$self->tool_wire_format` would *die* on a Perplexity engine. The literal `openai` is what
  keeps the shared `Role::OpenAICompatible` code path safe for an engine that has no tool
  dialect at all.

## Consequences

- **Deliberate keep: the tool-calling loop stays on the `locate` / `from_fmt` split, not
  `extract`.** `Role::Tools::response_tool_calls` returns raw structures via `locate`, and
  `extract_tool_call` parses one via `from_fmt`. The loop keeps the raw wire hashes (not parsed
  `ToolCall` objects) because it threads each raw `$tc` all the way to `format_tool_results`,
  which rebuilds the **Result envelope** (the **Assistant echo** plus per-result blocks) from
  provider-shaped raw fields (`$_->{tool_call}{id}`, `…{functionCall}{name}`, `…{call_id}`).
  Collapsing to `extract` would discard the raw structure too early. This split is preserved on
  purpose, not overlooked.
- A new provider that carries a wire-level tool_choice is added by extending `ToolChoice` and
  `%TO_METHOD`; one that does not (like Ollama/Hermes) simply isn't in the map and croaks loudly
  if asked — the absence is explicit.
- Cross-links: **ADR 0001** — this completes the value-object wire-translation symmetry it
  established and resolves its "Future work" item. **ADR 0003** — every `ToolCall` that
  `extract` produces lands on `Response.tool_calls`, the single sink. **ADR 0005** — records
  why Perplexity's named-tool request is a `response_format` rewrite, not a `tool_wire_format`
  value, which is why `to_perplexity` stays off the `to($fmt)` dispatch. `CONTEXT.md` fixes the
  vocabulary (the `ToolChoice` entry now describes the unified `to($fmt)` dispatch).
