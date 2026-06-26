# ADR 0005 — Structured output and forced tool calling are one mechanism; `chat_f` auto-rewrites between forms per capability

- Status: accepted
- Date: 2026-06-26
- Tags: tools, structured-output, chat_f, response-format, rewrite

## Context

A caller can ask for schema-shaped output three ways:

- `tools` — let the model choose to call a tool,
- a forced named `tool_choice` (`{type => 'tool', name => 'extract'}`) — make the
  model emit one specific tool call, i.e. extract a known schema,
- `response_format` (`json_object` / `json_schema`) — structured output with no tool.

On the wire the providers support *different subsets* of these. OpenAI does all three
natively. Anthropic does tools and named forcing but has **no native `response_format`**.
Perplexity does **no tool calling at all** but has native `response_format=json_schema`.
Gemini routes structured output through `generationConfig.responseSchema`, Ollama through
`format`.

Underneath, the three intents are the same capability: *schema-constrained generation*. A
forced named tool **is** structured output — the tool's `input_schema` constrains the
output. A `response_format` json_schema **is** a tool with no execution. They are
inter-convertible.

If each engine exposed only its native subset, the caller would have to know, per provider,
which of the three forms to send — and an "extract this JSON" request would simply fail on
Anthropic (no `response_format`) or on Perplexity (no tools). ADR 0001 removed per-format
*serialization* from the engines; this decision removes per-provider *form selection* from
the caller.

## Decision

Treat structured output and forced tool calling as two faces of one mechanism, and have the
engine layer **auto-rewrite between the forms in whichever direction the wire reality
requires**, keying the decision off `supports()` (ADR 0002). Two rewrite directions exist
today; native paths are left untouched.

1. **Forced named tool → `response_format`** (`Langertha::Role::Chat::chat_f`,
   `lib/Langertha/Role/Chat.pm:370-398`). When a caller forces a named tool on an engine
   that cannot do named-tool-forcing but can do json_schema
   (`!supports('tool_choice_named') && supports('response_format_json_schema')` —
   Perplexity), `chat_f` deletes `tools` + `tool_choice`, sets
   `response_format => { type => 'json_schema', json_schema => { %{ $tool->to_json_schema }, strict => true } }`,
   loose-parses the returned content (`decode_loose_json`), and attaches a `synthetic`
   `Langertha::ToolCall` carrying the parsed arguments.

2. **`response_format` → synthetic tool + forced choice**
   (`Langertha::Engine::AnthropicBase::_translate_response_format`,
   `lib/Langertha/Engine/AnthropicBase.pm:176-208`). When a caller asks for
   `response_format` on an engine with no native `response_format` but native forced tools
   (Anthropic), the engine synthesizes a tool from the schema (`Tool->to_anthropic`), forces
   `tool_choice` to it, and `chat_response` lifts the resulting `tool_use` input back into
   `Response.content` as JSON (`AnthropicBase.pm:244-246`).

3. **Both directions converge on the same output shape.** Every rewritten case lands a
   `Langertha::ToolCall` on `Response.tool_calls` (ADR 0003) and/or surfaces the structured
   payload as `Response.content` JSON, so the caller reads the result identically regardless
   of which way the rewrite went — or whether it happened at all.

4. **Native stays native.** The rewrite fires only on a capability gap. OpenAI forwards
   `response_format` verbatim; Gemini emits `responseSchema`; Ollama emits `format`. The
   capability registry (ADR 0002) is what decides *whether* a rewrite is needed.

## Rationale

The caller expresses the intent once and gets the same result shape on every provider. The
per-provider knowledge — "does this engine do `response_format`, or only forced tools, or
neither" — lives in the engine plus the capability registry, never in user code. Because a
tool definition and a json_schema `response_format` are inter-convertible, the framework
*converts* rather than refusing the request.

This is a distinct decision from its siblings: ADR 0001 says the value objects own per-format
*serialization*; ADR 0002 says capabilities are derived and queryable; ADR 0003 says
`Response.tool_calls` is the single *sink*. ADR 0005 is the decision in between — that the
engine layer will *rewrite one intent into another* to close a capability gap, treating
structured output and forced tool calling as one schema-constrained-generation mechanism.

## Consequences

- A new provider with a novel capability gap is handled by adding a rewrite branch keyed on
  `supports()`, not by adding a caller-facing API or a new `Response` field.
- The two rewrite sites sit at deliberately different layers: the forced-tool→`response_format`
  rewrite is in `chat_f` because it is engine-agnostic (any tools-less + json_schema engine
  benefits); the `response_format`→synthetic-tool rewrite is inside `AnthropicBase` because it
  is wire-specific to the Anthropic messages shape. They are not folded into one site because
  they apply at different scopes.
- The full decision matrix (what the caller passed × engine capabilities × resulting wire
  form) is documented in `README.md` ("Tool & Structured-Output Flow"); this ADR records the
  *why*, the README the *what*.
- Cross-links: ADR 0001 (the value objects — `Tool->to_json_schema`, `Tool->to_anthropic`,
  `ToolChoice` — perform the per-format serialization each rewrite invokes), ADR 0002
  (`supports()` gates every rewrite), ADR 0003 (the synthetic `ToolCall` is where every path
  lands). `CONTEXT.md` fixes the vocabulary (**ToolCall**, `synthetic`, **tool_wire_format**).
