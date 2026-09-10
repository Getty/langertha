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
   (Post-k139 Perplexity speaks the Agent API — the Open-Responses envelope, ADR 0020 — but
   still advertises `response_format_json_schema` and not `tool_choice_named`, so this direction
   still fires and Perplexity remains its only exemplar in the tree.)

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

## Update (k133 — first-party Anthropic gained native structured output)

Decision 2 assumed the Anthropic Messages API has **no native `response_format`**, so the only
way to honor a `response_format` on that wire was to synthesize a tool and force `tool_choice`
onto it. That is no longer true for the **first-party Claude API**: the Messages API now has
native structured output via **`output_config.format`** (`{ type => 'json_schema', schema =>
{...} }`, GA, no beta header). Decision 2's synth-tool rewrite is therefore **superseded for
`Engine::Anthropic`** and **kept, unchanged, for the legacy `/anthropic` shim engines**
(MiniMaxAnthropic, MoonshotAnthropic, AKIAnthropic, LMStudioAnthropic), whose shim endpoints do
not carry the field.

- **The split is a one-method opt-in.** `Role::AnthropicCompatible::_native_structured_output`
  defaults to `0` (shims keep the rewrite); `Engine::Anthropic` overrides it to `1`. On the
  native branch `_take_response_format` pulls the `response_format` off the per-request
  controls / `%extra` / engine attribute (the Messages API 400s if one reaches the wire),
  `_response_format_to_output_config` turns it into the `output_config.format` value (a bare
  `json_object` maps onto an open-object `json_schema`), and the content JSON rides back on the
  wire verbatim — no `chat_response` tool_use lift. On the shim branch
  `_translate_response_format` is exactly Decision 2, untouched.
- **Native structured output streams; the shim rewrite still cannot.** The synth-tool rewrite
  has no streaming counterpart to `chat_response`'s tool_use lift, so `chat_stream_request`
  croaks loudly on a shim rather than streaming unstructured text or leaking `response_format`
  onto the wire (karr #52). The native branch streams the JSON as ordinary text deltas.
- **Decision 1 (Perplexity: forced named tool → `response_format`) is unchanged and still
  valid.** Only Decision 2's Anthropic direction is nuanced.
- **The unify-and-rewrite core is reinforced, not overturned.** Decision 4 said *native stays
  native; the rewrite fires only on a capability gap*. First-party Anthropic simply graduated
  from the gap branch to the native branch — exactly the case Decision 4 anticipated. The same
  mechanism now runs the other way too: `claude-fable-5-1` / `claude-mythos-5-1` **reject**
  forced tool use (`tool_choice` `any` / `tool` → 400), so `Engine::Anthropic`'s
  `model_capability_corrections` clears their `tool_choice_named` / `tool_choice_any` flags and
  `chat_f`'s auto-rewrite routes a forced named tool *through the native structured-output path*
  on those models. Per-model wire truth lives in `model_capability_corrections`, not in `around
  engine_capabilities` — see **ADR 0019** (the ADR 0002 amendment, k138).
- **`output_config` is now shared by two request-side concerns.** `Langertha::Reasoning`
  already places reasoning effort under `output_config.effort` (ADR 0009); structured output
  now places its schema under `output_config.format`. A naive second `output_config` would
  silently drop one, so `Role::AnthropicCompatible::_merge_output_config_format` folds `format`
  into the existing hash — a **merge, not last-writer-wins**. This is a new kind of overlap for
  the ADR 0009 quartet (each concern used to own a disjoint body key); see the ADR 0009 Update.
- **`Tool->to_anthropic` now emits top-level `strict: true` for closed schemas**
  (`additionalProperties:false` + a non-empty `required`), keyed on the schema *shape* and so
  engine-agnostic — a value-object serialization extension in the spirit of ADR 0001 (the value
  object owns its wire shape). See the ADR 0001 strict-tool-use note.

This is an amendment in place, not a superseding ADR: the mechanism ADR 0005 records —
structured output and forced tool calling are one schema-constrained-generation mechanism, and
the engine layer rewrites between forms on a capability gap — stands entirely. One wire grew a
native capability, moving one engine from the rewrite branch to the native branch, which is the
behavior Decision 4 already specified. Contrast ADR 0006 → ADR 0013, where the thing itself
moved axes and a new number was right.
