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
The canonical tool-selection *policy* (none/auto/required/named). Serializes via
the same unified `to($fmt)` dispatch as the other value objects, over its
per-format serializers — keyed by `tool_wire_format`, for the wires that carry a
tool_choice parameter (openai/anthropic/gemini/responses). The original exemplar
of the value-object pattern the others now follow.
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

### Request-side controls (sibling seams)

The same value-object-per-wire-format pattern governs three sibling seams outside
tool-calling. Their canonical vocabulary lives in **ADR 0009** and **ADR 0012**
(not restated here); named only so the parallel is explicit:

**reasoning_wire_format** / **Langertha::Reasoning**:
The per-engine reasoning dialect (`openai` | `anthropic` | `gemini` | `responses`)
and the value object that clamps + places `reasoning_effort` onto it. Deliberately
separate from `tool_wire_format` — engines sharing one tool dialect diverge on
reasoning (DeepSeek/MiniMax/Groq are all `tool_wire_format=openai`).

**cache_wire_format** / **Langertha::PromptCache**:
The per-engine prompt-cache dialect — Anthropic `cache_control` (enable breakpoint)
vs OpenAI `prompt_cache_key` (routing hint); the two are asymmetric and carry
distinct capability flags.

**knob_wire_format** / **Langertha::Runtime::Knobs**:
The per-engine self-hosted runtime-knob dialect — `vllm` | `sglang` | `llamacpp` —
and the value object that clamps + places the prefix-cache isolation/reuse knobs
(`prefix_cache_salt`, `cache_prompt`, `n_cache_reuse`, `id_slot`, `priority`,
`return_cached_tokens_details`, `extra_key`) onto it. **No shared default:** an
`openai` knob dialect does not exist (the OpenAI cloud API has no such knobs), so
an engine that composes the role must set its tag explicitly or die at first use.
The three engines share `tool_wire_format=openai` yet accept disjoint knob field
sets — the knob dialect is a distinct concern from reasoning and caching. The
`prefix_caching` capability means *the wire accepts the controls*, not that the
server has caching enabled.

### Response-side observability (sibling seams)

Two sibling seams sit on the response side. Their canonical vocabularies
live in the ADRs (not restated here); named only so the parallels are
explicit:

**Langertha::Response.timing** (HashRef) — **ADR 0011**:
The response-side timing surface. Holds two classes of keys:
- *engine-agnostic* (standard): `ttft_seconds`, `total_seconds` — Float,
  seconds. `ttft_seconds` only meaningful for async streaming (LWP
  sync streaming buffers the body and cannot observe it).
- *engine-native* (optional, engine-populated): provider-specific stage
  durations. Currently Ollama: `total_seconds`/`load_seconds`/
  `prompt_eval_seconds`/`eval_seconds` (Float, seconds) plus the
  original `*_duration` keys in nanoseconds preserved for back-compat.

**_merge_timing_field** (Role::Chat private):
First-write-wins merge primitive. Provider-supplied keys (e.g. Ollama
server-reported `total_seconds`) trump client-measured values
(`Time::HiRes tv_interval` around the request). Rationale: server time
excludes network jitter, which is what model-latency dashboards want.
Round-trip latency is recoverable from the difference between
provider-native and client-measured `total_seconds` when both are
present.

**runtime_metrics** capability — **ADR 0014**:
The self-hosted observability seam. Engines that serve a Prometheus
`GET /metrics` endpoint (vLLM, SGLang, llama.cpp's built-in server)
compose `Langertha::Role::Runtime::MetricsPoll` and advertise the
`runtime_metrics` capability flag via `engine_capabilities`. The
role's `poll_metrics_f` (async, IO::Async) and sync `poll_metrics`
scrape the endpoint and return parsed
`Langertha::Runtime::Metrics` records; the URL is derived
mechanically by stripping the trailing `/v1` from the engine's
`url`. Ollama is intentionally not composed — its runtime stats
live at `/api/ps` in JSON, not at `/metrics` in Prometheus text.
The asymmetry between chat-shape flags (request body fields) and
the observability-shape flag (`runtime_metrics`) is documented in
ADR 0014.

## Relationships

- An engine declares exactly one **tool_wire_format**; its default follows the
  wire-envelope roles (`Role::OpenAICompatible`→`openai`,
  `Role::AnthropicCompatible`→`anthropic`, … — see ADR 0013), composed by thin engine bases.
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
