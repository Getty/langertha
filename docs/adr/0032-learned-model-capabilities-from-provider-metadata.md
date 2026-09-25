# ADR 0032 — Learned model capabilities: an explicit probe of the provider's own model metadata

- Status: accepted
- Date: 2026-09-25
- Tags: capabilities, model-scoped, image_input, value-objects, manifest, self-hosted, gateways
- Cross-links: ADR 0002, ADR 0019, ADR 0029, ADR 0027, ADR 0001
- karr: #270

## Context

`image_input` is model-scoped (ADR 0019 k266 Update): a true flag says the selected
`chat_model` sees an image. Cloud engines answer from static tables. Gateways (OpenRouter) and
self-hosted servers (Ollama, LM Studio, llama.cpp) could not: the model behind them is unknown
to the client, so they made no claim at all, and a knarr `/api/show` or a manifest built on them
said "no vision" for `llava` and `gpt-4o` alike.

These providers do publish the fact, in their own model metadata:

| Engine(s) | Endpoint | Field |
|---|---|---|
| OpenRouter | `GET {url}/models` | `data[].architecture.input_modalities` contains `image` |
| Mistral | `GET /v1/models` | `data[].capabilities.vision` (per `id` and `aliases`) |
| LMStudio, LMStudioOpenAI | `GET /api/v1/models` (native, beside `/v1`) | `models[].capabilities.vision` |
| Ollama, OllamaOpenAI | `POST /api/show {model}` (beside `/v1`) | `capabilities` contains `vision` |
| LlamaCpp | `GET /props` (beside `/v1`) | `modalities.vision` |

Shapes from each provider's documentation (lmstudio.ai `rest/list`, llama.cpp
`tools/server/README.md`, ollama `docs/api.md`, openrouter.ai models guide, Mistral models
endpoint reference), read 2026-09-25. None was live-verified; the test fixtures are shaped from
those documents.

Reading this metadata costs a request. `supports()` is called on hot paths (the `chat_f`
rewrite matrix, ADR 0005) and must never do network I/O.

## Decision

1. **An explicit, opt-in probe.** `$engine->probe_model_capabilities_f(models => [...])`
   (sync wrapper `probe_model_capabilities`) fetches the engine's metadata endpoint and stores
   the learned facts in a per-instance store, `{ $model_id => { $cap => 0|1 } }`. Without
   `models` it asks about `chat_model`. A document that describes every model (OpenRouter,
   Mistral, LM Studio) is fetched once and every model in it is learned; Ollama is asked once
   per model; llama.cpp serves one model, so its fact is stored under every id that was asked
   about. Nothing probes implicitly. `learned_model_capabilities` returns a copy of the store,
   `clear_learned_model_capabilities` empties it. Only non-empty plain strings are model ids
   (in `models` and in the documents). A model Ollama does not have (`/api/show` 404) gives no
   fact and the other models of the call are kept; any other non-success answer, or a success
   answer that is not JSON, fails the future with an engine-named error and stores nothing.

   Looking a fact up for `chat_model` is exact first, then the format's equivalent spelling
   (`ModelProbe->lookup_ids`): on Ollama a missing tag is `:latest` (`llava` ↔ `llava:latest`);
   on OpenRouter a routing variant (`:online`, `:free`, `:nitro`, …) falls back to its base id
   when the variant itself is not listed. Other formats match exactly. This is ADR 0018's
   "normalize, don't gatekeep" applied to ids the provider itself treats as the same model.

2. **A fourth layer, after layer 3.** `engine_capabilities` applies the learned facts for the
   current `chat_model` right after the static `model_capability_corrections` table, inside the
   base method. For a model the probe reported, **the probe is authoritative in both
   directions**: static no-claim + probe yes → yes; static yes + probe no → no. A model the
   document does not describe, or describes without the field, gets no fact and keeps its static
   answer.

3. **Two gates stay absolute.** A learned `1` re-asserts a flag only if the composed roles grant
   it (layer 1: the wire can carry the part at all). The engine's `around engine_capabilities`
   (layer 2) still wraps the whole method, so an endpoint that never carries the field stays
   closed whatever the metadata says. This is ADR 0019's "the endpoint gate is absolute", kept.

4. **The gateway / self-hosted no-claim moves from layer 2 to layer 3.** It was never a wire
   fact ("the endpoint cannot carry images"), only "the client does not know the model". On the
   probing engines (OpenRouter, Ollama, OllamaOpenAI, LMStudio, LMStudioOpenAI, LlamaCpp) the
   `delete $caps->{image_input}` in the `around` became a catch-all row
   `qr/\A/ => { image_input => 0 }`, so the learned layer can answer over it. Engines without a
   probe keep their layer-2 clear.

5. **The table walk resolves a croaking `chat_model` as no model.** OpenRouter and OllamaOpenAI
   have no default model; building `chat_model` croaks. `Role::Capabilities::_capability_model`
   turns that croak into `undef`, which the walk matches as `''` (the ADR 0019 k209 rule), so
   `supports()` keeps answering on a model-less engine with a catch-all row. The only other
   engine with a croaking default and a table, Groq, already returns an empty table without a
   model, so nothing changes there.

6. **Parsing lives on a value-object door keyed by a per-concern tag.** `Langertha::ModelProbe`
   (class methods, no I/O) reads a decoded document per `model_metadata_format`
   (`openrouter` | `mistral` | `lmstudio` | `ollama` | `llamacpp`), like the tool value objects
   are keyed by `tool_wire_format` (ADR 0001). An engine opts in with two hooks,
   `model_metadata_format` and `model_metadata_url`; the defaults are `undef`, and then the probe
   resolves to `{}` without a request. The two LM Studio faces and the two Ollama faces share a
   format across different parents without a new role.

7. **Scope: `image_input` only.** `ModelProbe->probed_capabilities` is the allowlist of what a
   probe may learn. Other fields in the same documents (Ollama `tools` / `thinking`, OpenRouter
   `supported_parameters`, LM Studio `trained_for_tool_use` / `reasoning`, Mistral
   `function_calling`) are not read: those flags drive the `chat_f` rewrite matrix (ADR 0005),
   where a learned fact would change what is sent, while `image_input` is advisory.

8. **The manifest publishes learned facts without extra code.** `Manifest::Builder` evaluates
   `engine_capabilities` per model on a `clone_object` of the engine; the clone shares the store,
   so a probed engine publishes its facts (ADR 0029). The store is replaced on write, never
   mutated in place, so a probe on a clone never writes into its source.

## Rationale

- **Opt-in, not lazy.** A lazy probe inside `supports()` would put a blocking request (or an
  unresolved Future) under `chat_f`, `Manifest::Builder` and knarr's request path. The caller
  knows when a network round-trip is acceptable (server start, manifest build); core does not.
- **Authoritative in both directions.** The static tables are documentation-derived and dated;
  the provider's own metadata describes the model actually served, including a quantized or
  renamed local build. Letting a static yes survive a provider no would keep a claim the
  provider itself contradicts.
- **After layer 3, not after layer 2.** Putting the learned layer outermost would need an
  `around` that is guaranteed to wrap every engine's own `around`, which Moose cannot promise
  across `with`/`around` order. Placing it inside the base method is deterministic, and keeping
  layer 2 on top preserves the wire gate. The price is decision 4: a "no claim" that should be
  overridable must live in layer 3.
- **A format tag, not engine methods.** Four of the five formats have two consumers from
  different parents (LMStudio/LMStudioOpenAI, Ollama/OllamaOpenAI). A value-object door keeps
  the parsers in one place without a `Role::<X>Compatible` extraction (ADR 0016).

## Consequences

- `supports('image_input')` on the probing engines answers per model after a probe; before one,
  every answer is unchanged (asserted in `t/78_image_input_capability.t` and
  `t/78_model_capability_probe.t`).
- `engine_capabilities` has four layers in evaluation order: role map (1), static per-model
  table (3), learned facts, then the engine `around` (2) on the outside.
- The store is per engine instance and in memory. knarr, which caches engine instances, keeps
  facts across requests; a fresh instance knows nothing until probed.
- A failed probe (non-2xx) fails the future with `<engine> model metadata probe failed:
  <status> - <body>` and stores nothing.
- LlamaCpp facts are keyed by the id asked about (`default` unless a model is configured);
  `Manifest::Builder` skips the `default` placeholder, so a manifest of a llama.cpp server needs
  `probe_model_capabilities(models => [$published_id])` first.

## Future work

- **TSystems.** The advisor named `meta_data.input_modalities` on its models endpoint, but the
  public docs (docs.llmhub.t-systems.net, API endpoints page) document `GET /v2/models` without a
  response schema, and no key exists to check it. Not implemented; `probe_model_capabilities_f`
  resolves to `{}` there.
- **Anthropic** `/v1/models` `capabilities.image_input` would be a cross-check of the static
  Claude table; not implemented (the static answer is already "yes" for Claude 3+).
- **LMStudioAnthropic** talks to the same LM Studio server as the other two faces and could
  reuse the `lmstudio` format; not composed yet.
- **More capabilities** (tools, reasoning) from the same documents need their own decision,
  because they change what `chat_f` sends.
