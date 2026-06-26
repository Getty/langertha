# ADR 0003 — `Response.tool_calls` is the single source of truth for emitted tool calls

- Status: accepted
- Date: 2026-06-26
- Tags: tools, response, tool-calls, structured-output

## Context

A model can emit a tool call through several distinct mechanisms, each with its own wire shape:

- a **native** tool call (`tool_calls` in `choices[0].message`, Anthropic `tool_use` blocks,
  Gemini `functionCall` parts, Responses `function_call` items),
- a **Hermes** `<tool_call>` XML payload parsed out of plain text,
- a **forced-tool fallback** that `chat_f` synthesizes when the wire reality won't take the
  caller's request directly — e.g. Perplexity (no tool calling) where a `tool_choice` of a
  named tool is rewritten to `response_format=json_schema` and the parsed content is turned
  back into a tool call; or Anthropic structured output, where a `response_format` is satisfied
  by a synthetic tool plus a forced `tool_choice` and the `tool_use` input is lifted out.

If callers had to branch on which mechanism produced the call, every consumer of a `Response`
would have to know all of the above — the exact coupling ADR 0001 removed from the engines.

## Decision

1. **`Langertha::Response.tool_calls` is `ArrayRef[Langertha::ToolCall]` — the one place
   emitted tool calls live**, native and synthetic alike. Whatever mechanism produced the call,
   it is normalized to a `Langertha::ToolCall` and lands on this one list. There is no second,
   parallel tool-call representation on the response.

2. **A `synthetic` flag on `Langertha::ToolCall` records provenance** — true for the
   forced/rewritten fallbacks, false for calls the model emitted natively. This keeps the
   distinction (did the model choose this tool, or did we synthesize it to satisfy a request?)
   without introducing a second type. The `chat_f` auto-rewrites attach `synthetic` ToolCalls
   so the caller still reads one uniform shape.

## Rationale

One representation means a `Response` consumer iterates `tool_calls` and is done — it never
learns that Perplexity has no native tools or that Anthropic structured output is implemented
with a forced tool. The rewrites in `chat_f` (ADR 0001's value objects do the per-format
parsing; the capability registry of ADR 0002 decides *whether* to rewrite) stay invisible above
the seam. The `synthetic` flag is the minimum needed to preserve the one piece of information a
caller might legitimately want — provenance — without leaking the mechanism.

## Consequences

- Consumers (including `Raider`) read `Response.tool_calls` uniformly; provider quirks do not
  reach them.
- A new forced-tool fallback is added by producing `synthetic` ToolCalls, not by inventing a
  new response field — the shape stays closed.
- Streaming follows the same rule: `Stream::Chunk` carries an optional `tool_calls` field and
  `Role::Chat::aggregate_tool_calls(\@chunks)` collects them into the same `Langertha::ToolCall`
  list, so streamed and non-streamed responses converge on one representation.
