# Capability flags and request controls

Read this when you need the exact `supports()` flag name, or the knob for reasoning, caching,
self-hosted runtime tuning or another request-side control.

## `supports()` flag names

`$engine->supports('tool_choice_named')`; `$engine->engine_capabilities` is the HashRef.

`chat streaming tools_native tool_choice_{auto,any,none,named} tools_hermes
response_format_json_{object,schema} embedding transcription image_generation temperature
reasoning_effort prompt_cache prompt_cache_key cached_content seed context_size response_size
system_prompt keep_alive parallel_tool_use runtime_metrics prefix_caching server_tools
image_input stream_usage`

The `%ROLE_TO_CAPS` map in `Langertha::Role::Capabilities` is the authority.
`image_input` is model-scoped ("this model sees images"); it never blocks sending.

## Request controls

Set on the engine, or per request through `chat_f`:

- `reasoning_effort` (`none minimal low medium high xhigh max`; values the wire cannot take are
  dropped), `thinking_budget` (Gemini 2.5), `thinking_display` (Anthropic).
- `prompt_cache` / `prompt_cache_ttl` (Anthropic `cache_control`), `prompt_cache_key` (OpenAI).
  A 200 does not prove a cache write; check `usage`.
- Self-hosted (vLLM, SGLang, llama.cpp): `prefix_cache_salt`, `cache_prompt`, `n_cache_reuse`,
  `id_slot`, `priority`, … and `poll_metrics_f` (Prometheus `/metrics`).
- Also: `temperature`, `seed`, `response_size`, `context_size`, `parallel_tool_use`,
  `keep_alive` (Ollama native), Gemini `create_cached_content_f` & co.
