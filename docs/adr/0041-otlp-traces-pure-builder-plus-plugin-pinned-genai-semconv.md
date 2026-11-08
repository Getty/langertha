# ADR 0041 — OTLP traces: a pure payload builder (`Trace::OTLP`) plus a PluginHost plugin (`Plugin::OTel`), GenAI semantic conventions pinned at v1.41.1, content off by default

- Status: accepted
- Date: 2026-11-08
- Tags: observability, otel, plugins, usage, value-objects
- Cross-links: ADR 0005, ADR 0014, ADR 0027, ADR 0028, ADR 0031, ADR 0034
- karr: k403 (follow-ups k404, k405, k406, k407)

## Context

Until now Langertha could trace LLM calls only into Langfuse's own ingestion API
(`Plugin::Langfuse`, `Role::Langfuse`). Most observability stacks take OpenTelemetry instead:
an OpenTelemetry Collector, Grafana Tempo, Phoenix, OpenLIT, and Langfuse itself through its
OTLP endpoint. OpenTelemetry describes LLM calls with the GenAI semantic conventions
(`gen_ai.*` attributes, `chat` / `embeddings` / `execute_tool` operations).

Four facts shaped the design:

- The GenAI conventions are marked *Development*. They changed between releases, and
  semantic-conventions v1.42.0 deprecated every `gen_ai.*` attribute and moved them to a
  separate GenAI conventions project that has no release yet. Whatever Langertha emits has to
  name the exact convention version it follows.
- A program that sees LLM traffic without a Langertha host (a proxy, a gateway) wants the same
  `gen_ai.*` mapping without composing an engine.
- Core has no conversation-end hook. A plugin sees `plugin_before_llm_call` /
  `plugin_after_llm_response`, the tool-call hooks and the embedding / image hooks, but never
  "this conversation is over".
- `Langertha::Usage.input_tokens` keeps the wire's meaning (ADR 0031): on Anthropic it excludes
  the cache reads and writes, on most providers the cache split is not reported at all. The
  conventions define `gen_ai.usage.input_tokens` as the *total* input, cache included.

Prompts, answers and tool arguments routinely carry personal or confidential data, and a trace
backend is often run by a different team, with different retention, than the application.

## Decision

**1. Two layers: a pure builder and a plugin.**
`Langertha::Trace::OTLP` is a payload builder with no transport, the trace sibling of
`Langertha::Runtime::Metrics::OTLP`. It turns neutral span records (`trace_id`, `span_id`,
`parent_span_id?`, `name`, `kind`, `start`, `end`, `status?`, `attributes`, `events?`) into an
OTLP/HTTP JSON `resourceSpans` payload, and its class methods (`provider_name`,
`request_attributes`, `response_attributes`, `usage_attributes`, `call_result_attributes`, id
generators) map Langertha objects to `gen_ai.*` attributes. It needs no Langertha host.
`Langertha::Plugin::OTel` is a `Role::PluginHost` plugin with the same hooks and flush
semantics as `Plugin::Langfuse`; it builds spans with `Trace::OTLP` and POSTs them.
The only encoding is OTLP/HTTP JSON: no protobuf, no OpenTelemetry SDK dependency.
`OTEL_EXPORTER_OTLP_(TRACES_)PROTOCOL` set to anything but `http/json` gets one warning, not a
different encoding. The builder has its own typed attribute encoder (token counts, seed, port
as `intValue`; temperature, top_p, TTFT as `doubleValue`; ids and models always
`stringValue`); it deliberately does not reuse the metrics encoder, which turns numeric-looking
strings into doubles.

**2. The conventions are pinned at semantic-conventions v1.41.1.**
Every payload names `schemaUrl` `https://opentelemetry.io/schemas/1.41.1`
(`Trace::OTLP::SCHEMA_URL`, `SEMCONV_VERSION`), and both modules name the version and the
reason in their POD. v1.41.1 is the last release that carries the GenAI conventions. The
deprecated `gen_ai.system` is never emitted; `gen_ai.provider.name` replaces it. Re-pinning
onto the separate GenAI conventions project once it releases is k404.

**3. The exporter, not `Usage`, adds the cache to the input count.**
`usage_attributes` sends `gen_ai.usage.input_tokens` = `input_tokens` + cache reads + cache
writes when `input_includes_cache` is false, and `input_tokens` unchanged when it is true or
`undef` (the provider did not report a cache split). The cache counts also go out separately as
`gen_ai.usage.cache_read.input_tokens` / `gen_ai.usage.cache_creation.input_tokens`, and
reasoning tokens as `gen_ai.usage.reasoning.output_tokens`, each only when non-zero.
`Langertha::Usage` is unchanged: ADR 0031 stands as written.

**4. `capture_content` is off by default.**
Off, no prompt, answer, system prompt, tool argument or tool result text appears anywhere in
the payload: only metadata. On, the content goes out as JSON-string attributes in the
conventions' message shape: `gen_ai.input.messages` (the conversation sent, system messages
included as `system`-role messages, not as `gen_ai.system_instructions`),
`gen_ai.output.messages`, and on tool spans `gen_ai.tool.call.arguments` /
`gen_ai.tool.call.result`. Image bytes are stripped exactly as in `Plugin::Langfuse`.

**5. The span model.**

- One trace per conversation: the trace id is kept until `reset_trace`.
- **No synthetic root span.** The LLM-call spans are the top level of the trace (k405 tracks a
  conversation-end hook that would allow one).
- One `CLIENT` span per LLM call, `"{operation} {model}"`, from `plugin_before_llm_call` to
  `plugin_after_llm_response`.
- Each tool call is an `INTERNAL` span `execute_tool {name}`, a **child of the chat span that
  requested it**.
- Embeddings are operation `embeddings`; image generation is operation `generate_content` with
  `gen_ai.output.type` `image`.
- `gen_ai.provider.name` comes from an **explicit table** keyed by engine class (walking the
  `isa` chain for subclasses, `_OTHER` when nothing matches), never from a lowercased class
  name. The conventions' well-known values are used where they exist (`gcp.gemini`,
  `mistral_ai`, `x_ai`); the dialect faces of one service share a name (`AKI*` → `aki`,
  `LMStudio*` → `lm_studio`), and a gateway names the gateway (`openrouter`, `huggingface`,
  `replicate`), not the upstream model vendor. The plugin's `provider_name` overrides it.
- `session_id`, when given, goes out as both `gen_ai.conversation.id` and `session.id`; no
  conversation id is ever generated.

**6. Shared plugin internals live in `Langertha::Role::TracePlugin`.**
The JSON-safe snapshot with image stripping (`_json_safe`), the flush-engine lookup and the
non-blocking `auto_flush` with held pending futures moved out of `Plugin::Langfuse` into this
role, which both tracing plugins compose. It is internal: not public API, composed by plugins,
never by an engine, and not a capability (listed as such in `t/78_capability_registry.t`).
`Plugin::Langfuse` behavior is unchanged.

## Rationale

- **Builder without transport.** A payload builder is testable against the OTLP JSON shape
  with no network, and a proxy or a sibling distribution can reuse the `gen_ai.*` mapping
  without a host. It follows the precedent of `Runtime::Metrics::OTLP`.
- **JSON only, no SDK.** OTLP/HTTP JSON is accepted by every receiver named above, and a hand
  encoder of a few hundred lines is cheaper than pulling an OpenTelemetry SDK and a protobuf
  stack into every installation of a framework whose transport is already optional (ADR 0027).
- **Pinned version.** With the conventions in *Development* and the `gen_ai.*` namespace
  formally deprecated in the next release, an unpinned exporter would silently drift. The
  `schemaUrl` lets a backend translate, and the pin makes a later re-pin a deliberate change.
- **Cache folding at the export door.** ADR 0031 keeps `Usage` faithful to the wire so that
  pricing counts each token once; changing `input_tokens` to match one external convention
  would break that. The conventions' meaning is a property of the export, so the export does
  the conversion. `undef` is left as is because the wire gave no split to add.
- **Content off.** Shipping prompts to a third-party backend is a data-protection decision the
  caller has to make; the safe default sends metadata only. The system prompt stays in
  `gen_ai.input.messages` because the hooks see it as a message in the conversation, already
  in the engine's wire shape; splitting it out per dialect would add a second mapping for no
  gain to readers of the trace.
- **No root span.** A root span needs an end; without a conversation-end hook it would either
  never end or end at an arbitrary call. A trace of top-level LLM-call spans sharing one trace
  id is valid OTel and loses nothing a backend needs to group them.
- **Tool spans under the requesting chat span.** That chat span is the cause of the tool call.
  A child that outlives its parent (the tool runs after the chat response) is valid OTel.
- **Explicit provider table.** Class names are Langertha's spelling (`XAI`, `LlamaCpp`,
  `AKIAnthropic`); lowercasing them would produce values no backend recognizes and would split
  one service across several names. A gateway names itself because that is the party that
  received the request and billed it.
- **A role for shared plumbing.** Copying `_json_safe` and the `auto_flush` handling into a
  second plugin would let the two drift on exactly the parts that must behave alike (image
  stripping, never blocking the call). Keeping the role internal leaves it free to change.

## Consequences

- Any OTLP/HTTP JSON receiver can take Langertha traces; Langfuse can be fed either way.
- A receiver that only accepts protobuf cannot be used directly; a Collector in between can
  convert.
- Attribute names may change when k404 re-pins onto the GenAI conventions project; the
  `schemaUrl` changes with them.
- `gen_ai.usage.input_tokens` on an Anthropic span differs from `Response->usage->input_tokens`
  by the cache counts. That is intended (decision 3).
- Calls that fail before `plugin_after_llm_response`, and the streaming chat methods, leave no
  span: no hook reports them (k407).
- New engines need a row in the provider table, or they export `_OTHER` unless a parent class
  has one.

## Future work

- **k404** — re-pin onto the separate GenAI semantic conventions project once it has a
  release (its unreleased main already renames some provider values and
  `cache_creation.input_tokens` → `cache_write.input_tokens`): `schemaUrl`, provider table, POD.
- **k405** — a conversation-end hook in core, which would allow a root span.
- **k407** — a hook for a failed LLM call and an after-hook for streamed replies, so trace
  plugins can emit error spans, `gen_ai.request.stream` and the time to first chunk.
- **k406** — `gen_ai.response.finish_reasons` is read from `Response.finish_reason`, which
  core overwrites to `tool_calls` when `chat_f` synthesizes a `ToolCall` for structured output
  (ADR 0005), so a trace reports a tool call the model never made; decide whether the response
  keeps the provider's raw value.
