# ADR 0019 — The Open-Responses wire envelope is a composed role; divergent parents meet in overridable hooks

- Status: accepted
- Date: 2026-09-10
- Tags: engines, inheritance, roles, composition, wire-format, symmetry, responses, perplexity

## Context

ADR 0016 fixed the rule for *when* a wire envelope earns a `Role::<X>Compatible`: **at the
moment a second consumer needs that envelope while descending from a different parent** — never
ahead of that, never for symmetry alone. It named ADR 0013 (the Anthropic extraction) as the
*outcome* of that trigger, "not a template to be applied ahead of it", and its Consequences
directed that any actual extraction be done "as part of that shim's ticket, following the ADR
0013 shape".

k139 is the first firing of that trigger, and the cleanest example of it in the tree.

Before k139 the Open-Responses wire envelope — `input` instead of `messages`, top-level
`instructions`, flat tool objects, an `output[]` array discriminated by `type`,
`input_tokens`/`output_tokens` usage, the typed-SSE stream — lived inline in
`Engine::OpenAIResponses` (a subclass of `Engine::OpenAI`), exactly as the Anthropic envelope
once lived inline in `Engine::AnthropicBase`. It had one consumer, so ADR 0016 kept it in the
class.

Two facts made k139 fire the trigger:

1. **Perplexity retired its Sonar Chat Completions surface** (EOL 2026-09-27, karr k139). The
   named successor is the **Agent API** (`POST /v1/agent`), which speaks the *same*
   Open-Responses envelope — not `/chat/completions`. So a second consumer of that envelope now
   exists.
2. **That second consumer cannot inherit from the first.** `Engine::OpenAIResponses` reaches
   the envelope through the full OpenAI dialect (`extends OpenAI` → `OpenAIBase` → `Remote`:
   Bearer auth, key, model list, OpenAPI spec). Perplexity's Agent API shares *none* of that
   dialect — it is a lean engine that needs only `Engine::Remote`'s auth+HTTP+JSON and would
   inherit wrong capability flags (embeddings, whisper, `json_object`) and the wrong dispatch if
   it extended `OpenAIBase`. The two consumers descend from **different parents**.

This is the case ADR 0016's decision 1 describes literally but the Anthropic precedent (ADR
0013) never actually exercised: `AnthropicCompatible`'s consumers all share one parent
(`AnthropicBase`), so its extraction could be a byte-identical *pure move*. Here the parents
diverge, so the extraction cannot be a pure move — the envelope has to absorb the divergence
somewhere.

## Decision

Extract the Open-Responses envelope from `Engine::OpenAIResponses` into
**`Langertha::Role::ResponsesCompatible`**, placed symmetrically alongside
`Role::OpenAICompatible` and `Role::AnthropicCompatible` — the third wire-envelope role. The
role owns the envelope body: `chat_request`, `chat_response`, `chat_stream_request`,
`parse_stream_chunk`, `stream_format`, the `output[]` walker, usage normalization
(`input_tokens`/`output_tokens` → `prompt_tokens`/`completion_tokens`), `_parse_function_call`,
`_responses_text_format`, and the wire-format builders (`_build_tool_wire_format` and
`_build_reasoning_wire_format` → `responses`; `chat_operation_id` → `createResponse`).

### Divergence lives in five overridable hooks, not in subclass branching

Because the two consumers descend from different parents, the role carries the OpenAI-Responses
behaviour as the **default**, and factors every point where Perplexity's Agent wire diverges
into one overridable method. Divergence is by-hook, never by `ref($self)` test:

| Hook | OpenAI-Responses default | Perplexity Agent override |
|---|---|---|
| `_responses_model_kwargs` | `model => chat_model` | `preset => …` (the four sonar ids map to fast/low/medium/high) or `model` pass-through |
| `_responses_format_kwargs` | `text => { format => … }` (flat json_schema) | top-level `response_format => …` (Chat-Completions shape) |
| `_responses_dispatch` | OpenAPI operation `createResponse` → `/v1/responses` | direct `POST …/v1/agent` (`generate_http_request`) |
| `_normalize_input_item` | pass `{ role, content }` through | stamp `{ type => 'message', … }` (typed items) |
| `_responses_extra_fields` | none | lift `search_results` → `Response.citations` |

The seam the role does **not** own is authentication: each consumer supplies its own `api_key`
/ `update_request`, so the role never clobbers an inherited key builder. `OpenAIResponses` keeps
OpenAI's Bearer/key/model-list by inheritance; `Perplexity` declares its own Bearer
`update_request` on `LANGERTHA_PERPLEXITY_API_KEY`.

### The two consumers

- **`Engine::OpenAIResponses`** — `extends OpenAI`, `with Role::ResponsesCompatible`. A thin
  shell: inherits the OpenAI dialect, composes the envelope on top, takes all five hook
  defaults, and opts out of streaming (`stream_format => undef` + `around engine_capabilities`
  clears `streaming`). Behaviourally unchanged by the extraction.
- **`Engine::Perplexity`** — `extends Remote` (auth + HTTP + JSON only), composing the
  universal chat roles plus `Role::ResponsesCompatible` via the explicit `-excludes` list (ADR
  0015): `Role::ReasoningEffort => { -excludes => ['_build_reasoning_wire_format'] }` so the
  role's `responses` builder wins, exactly as `AnthropicBase` wires `AnthropicCompatible`. It
  overrides all five hooks and keeps streaming (`stream_format => 'sse'`).

### Capabilities stay honest by composition (ADR 0002)

Perplexity's flag set follows what it composes, with one wire-reality correction. It composes
**no** `Role::Tools` (so `tools_native` / `tool_choice_named` stay off — see the ADR 0005 note
below), **no** `Role::PromptCache` (caching is automatic on the Agent API — no request-side
key), and **does** compose `Role::ReasoningEffort` (`reasoning_effort` on, wire
`reasoning.effort`). The single `around engine_capabilities` correction deletes
`response_format_json_object`, because the Agent API's `response_format` enum is
`json_schema`-only. This replaces the pre-k139 engine that inherited `OpenAIBase`'s flags and
then had to `delete` the ones that were wrong (embeddings, whisper, tool calling) — the lean
composition makes the inventory truthful up front rather than by subtraction.

## Rationale

**Why a role at all, and why now.** ADR 0016's trigger — a second consumer from a different
parent — fired for the first time. Keeping the envelope in `OpenAIResponses` would force
Perplexity to either inherit the whole OpenAI dialect (dishonest capabilities, wrong dispatch)
or re-implement the entire Open-Responses body a second time. The role is the only option that
leaves both consumers speaking one maintained envelope.

**Why its own ADR rather than an amendment to 0016.** 0016 is the *rule*; this is an *instance*
of the rule firing, and 0016 explicitly delegates the recording of an actual extraction to a
"0013-shaped" ADR tied to the shim's ticket. Folding a concrete role plus a new hook pattern
into the policy ADR would conflate the trigger with a firing of it. This ADR is to
`ResponsesCompatible` what 0013 is to `AnthropicCompatible`.

**Why hooks and not a subclass split.** 0013 could be a byte-identical pure move because its
consumers shared a parent; the request-body tests carried it unchanged. Here the parents diverge
on five concrete slots (model vs preset, `text.format` vs top-level `response_format`, OpenAPI
vs direct POST, typed vs pass-through input, extra citation fields). Branching those inside the
role on the concrete class would rebuild the entanglement the role exists to dissolve; an
overridable method per slot keeps the OpenAI path as the readable default and each divergence
named and local. This is the piece of architecture 0013 and 0016 do not describe, and the
reason this decision is worth its own number.

## Consequences

- The Open-Responses envelope is now a composable Moose role mirroring `Role::OpenAICompatible`
  and `Role::AnthropicCompatible`; it is classified as a wire envelope in
  `t/78_capability_registry.t` and catalogued in `Langertha.pm`.
- **Adding a third Open-Responses consumer** = compose `Role::ResponsesCompatible` and override
  only the hooks whose wire slots differ; nothing else is re-implemented. If the new consumer's
  divergence does not fit an existing hook, add a hook (OpenAI default + override), do not branch
  on the class.
- ADR 0016 is confirmed by a live firing, and ADR 0013's shape is confirmed as the template for a
  firing — with the hook layer as the addition demanded by consumers on different parents.
- ADR 0006 is nuanced exactly as 0013 nuanced it: inheritance still encodes the transport root
  (`Remote`); a third dialect envelope now lives on the role axis. Capabilities still derive from
  the composed roles (ADR 0002).
- Perplexity remains the sole exemplar of the ADR 0005 rewrite direction 1 — see the note added
  there.
- **Cross-links:** **ADR 0016** (the trigger this fires — first different-parent firing),
  **ADR 0013** (the precedent envelope role and the shape followed here), **ADR 0006** (dialect
  axis / capability axis this sits on), **ADR 0002** (capabilities by composition — the lean
  Perplexity inventory), **ADR 0005** (direction-1 exemplar preserved), **ADR 0015** (`-excludes`
  canon for the lean composition), **ADR 0001** / **ADR 0009** / **ADR 0010** (`responses`
  `tool_wire_format` / `reasoning_wire_format` and the value-object dispatch the envelope routes
  through), **ADR 0017** (`created_at` via `Moment->from_wire`). `CONTEXT.md` fixes the
  vocabulary (**wire envelope**, **dialect axis**, **capability axis**; the `responses` format).

## Future work

- karr **k147** — the Perplexity Agent API wire is built to the documented Open-Responses shape,
  not yet verified against a live call. Eight wire points are annotated `LIVE-CONFIRM (k139)` in
  `Engine::Perplexity` / `Role::ResponsesCompatible` (typed-input requirement, `response_format`
  slot + `strict`, model→preset mapping and which real model each preset runs, citation
  block/marker shape, retrieve path, typed-SSE framing). A live call (approval-gated) resolves
  them; nothing here blocks on it.
