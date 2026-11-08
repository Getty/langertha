# ADR 0028 — A public hook surface for sibling distributions; core promises no event loop

- Status: accepted
- Date: 2026-09-25
- Tags: api, async, transport, observability, usage, cross-dist
- karr: #190, #192 (raider side: #195)

## Context

ADR 0026 moved Raider into the sibling distribution langertha-raider, which depends on core
and never the reverse. The extracted code still reached into core internals. It sent its own
requests through `$engine->_async_http->do_request`, borrowed `$engine->_async_http->loop` to
add a `Net::Async::MCP` notifier and to run the `wait` self-tool's timer, stamped Langfuse spans
with `$engine->_langfuse_timestamp`, and parsed provider usage by hand in three places (two in
`Raider.pm`, one in `Plugin::Trace`). An inventory showed that langertha-knarr and langertha-skeid
call no engine privates.

ADR 0027 made `_async_http` / `_async_loop` a documented injection seam, but guaranteed only the
`do_request` contract. An injected client or the `SyncHTTP` fallback may have no `->loop`, and
IO::Async is only a `recommends`. Raider's `->loop` call worked only because raider itself
requires Net::Async::HTTP. It was never part of the contract.

## Decision

Core gains a small public hook surface, sized to what a sibling distribution actually calls. It
is not a general framework rework:

1. **`$engine->async_request_f($http_request, %opts)`** (`Role::AsyncHTTP`) is the public face of
   the ADR 0027 `do_request` contract. It returns `Future<HTTP::Response>`, and `%opts` (for
   example `on_header`) pass through. It returns a response, not the backend object. The parity
   scope is exactly ADR 0027's. HTTP error statuses resolve on every backend. Transport-level
   failures do not behave the same way: on Net::Async::HTTP they fail the future, while on the
   sync fallback they resolve with LWP's synthesized 500. Callers always check `is_success`.
2. **`$engine->async_loop`** (`Role::AsyncHTTP`) returns `Maybe[loop]`. It gives the event loop
   of the active backend: the injected client's loop if the client `->can('loop')`, the loop the
   default Net::Async::HTTP backend was added to (`_async_loop`, which is itself a constructor
   argument), or `undef` for the sync fallback or a client without a loop. **Core promises no
   loop.** A caller that needs one uses `$engine->async_loop // IO::Async::Loop->new`.
3. **`$engine->langfuse_timestamp`** (`Role::Langfuse`) returns "now" in the ISO-8601
   millisecond `Z` format that every Langfuse event carries.
4. **`Langertha::Usage->from_raw($body)`** is the inbound door for a raw decoded provider body,
   the value `parse_response` returns. It locates `usage`, `usageMetadata`, `response.usage`, or
   Ollama-native top-level counts, and returns `undef` when the body reports no usage.
   `from_hash` also reads Gemini's camelCase counts, following ADR 0018's universal tier.
   `from_response` routes HashRef bodies through `from_raw`.

The private names (`_async_http`, `_async_loop`, `_langfuse_timestamp`) stay alongside the new
public ones. `_async_http` and `_async_loop` remain the injection seam. `_langfuse_timestamp`
delegates to the public name. Sibling distributions migrate in their own repositories (#195).

## Rationale

The loop question had two candidate rulings. In (b), raider brings its own loop via the
`IO::Async::Loop->new` singleton. Review reproduced a silent hang under (b). If the backend runs
on a foreign loop (an injected client, or `_async_loop => $loop`), a raid awaits futures from two
loops, and the outer `->get` drives only one of them. Ruling (a) fixes that case with no extra
configuration. `async_loop` hands back the loop the HTTP futures really run on. The `undef`
fallback is needed only where no loop exists. Typing it `Maybe[loop]` keeps ADR 0027's promise
that core is sync-capable and IO::Async-free.

A method is preferred over exposing `_async_http` publicly. It publishes the contract
(`do_request` semantics, the loop question) rather than an object whose other methods callers
would start depending on. That dependence is exactly how the `->loop` reach-in arose.

Usage extends the existing value object instead of adding a new one. `from_raw` returning
`undef` lets a caller tell "not reported" from "zero tokens". The always-a-Usage `from_response`
could not express that.

## Consequences

- Sibling distributions can drop every reach-in listed above. The core names they rely on are now
  public and tested (`t/46_public_raider_hooks.t`).
- `Usage->from_response` on a raw HashRef now parses Gemini, Ollama-native and `response.usage`
  bodies that used to yield zeros. Downstream figures built on it change from 0 to real values;
  skeid's `metrics.normalize` and `estimate_cost` are examples.
- Engine-scoped usage spellings (AKI native `prompt_length` / `num_generated_tokens`) and
  Gemini's cache count are not covered by `from_raw`. They are tracked in karr #197.
- Relates to ADR 0026 (the extraction this completes) and ADR 0027 (the transport seam these
  hooks front; its parity scope applies verbatim). Relates to ADR 0018 (the camelCase spelling
  added at the universal door).

## Future work

- karr #195: the raider-side migration.
- karr #197: Gemini's usage rename duplicating `from_hash`,
  Gemini's missing `cached_tokens`, and AKI native counts in `from_raw`.

## Update (k197 — AKI native counts reach `from_raw` and `Response->usage`; Gemini cache count reaches `cached_tokens`)

`from_raw` now also recognizes AKI.IO's native top-level `prompt_length` / `num_generated_tokens` /
`num_cached_tokens` (the same keys `Engine::AKI` reads). They are the provider's own spelling of
the canonical counts, so they belong at the universal door (ADR 0018 tier 1), not only in the
engine. The Ollama top-level probe now follows `Engine::Ollama`: a zero count is "not reported",
so a body whose counts are all zero gives `undef`, not `Usage(0)`.

A body that reports only `num_cached_tokens` still yields a `Usage` carrying it, as the engine
does.

`from_hash` maps Gemini's `cachedContentTokenCount` (and the engine's renamed
`cached_content_token_count`) to `cached_tokens`, read after the OpenAI and Anthropic spellings,
and finally a flat canonical `cached_tokens` key. `Engine::Gemini` keeps its snake_case rename of
`usageMetadata`: `Usage`'s `%{}` overload serves that hash verbatim, so
`$response->usage->{prompt_tokens}` and `{cached_content_token_count}` are legacy keys kept for
compatibility, not deprecated (said so in `Langertha::Usage`'s HASH OVERLOAD POD).

The engine path had the same gap. `Engine::AKI::chat_response` passed `num_cached_tokens` as an
explicit `Response` argument but left it out of its `usage` hash, so `Response->cached_tokens` was
16 on the capture while `Response->usage->cached_tokens` was `undef`. The engine now puts the count
into that hash as `cached_tokens`, the flat key `from_hash` reads, and `Response->cached_tokens` is
lifted off the parsed `Usage` like every other engine. The existing `usage` hash keys
(`prompt_tokens`, `completion_tokens`) are unchanged; one key, `cached_tokens`, is added. Both
the `from_raw` door and the engine path now report all three AKI counts, which resolves the
consequence above that listed these gaps.

## Update (k226 — the hook surface grows to the plugin host)

The original inventory covered engine privates only. Raider also composes `Role::PluginHost`
and runs its own hook chain on top of it: `Raider.pm` iterates `$self->_plugin_instances` at ten
call sites and calls `$self->_plugin_pipeline_tool_call`, `Raider/CLI.pm` reads
`$raider->_plugin_instances`, and Raider's POD and tests use the `_plugin_args` constructor key.
langertha-knarr and langertha-skeid touch no plugin-host privates.

`Role::PluginHost` gains three public names, sized to exactly those uses:

1. **`plugin_instances`** — the read-only, lazily built ArrayRef of plugin objects, in
   `plugins` order. It is the attribute now; `_plugin_instances` is a method that returns the
   same list. The constructor key stays `_plugin_instances`, unchanged, so the public name
   does not become a new injection point.
2. **`plugin_args`** — the HashRef of constructor args for every plugin built from a name. The
   old `_plugin_args` constructor key is still accepted and used when `plugin_args` is absent;
   `plugin_args` wins when both are given. `_plugin_args` is a reader alias.
3. **`plugin_pipeline_tool_call_f`** — runs `plugin_before_tool_call` through the plugins as a
   pipeline and resolves to the final `($name, $input)`, or to the empty list when a plugin
   skips the call (later plugins are not asked). The `_f` suffix follows `fire_event_f`: both
   return Futures. `_plugin_pipeline_tool_call` delegates to it.

As with the engine hooks, the private names stay as aliases and the sibling migrates in its own
repository. The contract is pinned in `t/46_public_plugin_hooks.t`. Core's own hosts (`Chat`,
`Embedder`, `ImageGen`) still call the private names internally; that is behavior-neutral and can
move in a later change.

## Update (k341 — the tool-loop reply reader)

Since k321 the three core tool loops read each reply through the engine's `chat_response`, the
parser `chat_f` uses, via the private `Role::Tools::_tool_loop_response`: an error in a 200 body
croaks with `chat_f`'s text, the final text is `chat_f`'s content, and the calls to run are
`Response.tool_calls` (hermes calls lifted out of the text). k339 added the blocked-prompt croak,
and k324 the private `_tool_loop_calls`, which drops calls whose arguments were cut off by the
token limit and returns the echo body without them. langertha-raider runs its own loop and still
read the raw body (`parse_response`, `response_tool_calls`, `response_text_content`), so it had
none of this.

`Role::Tools` gains two public names, the minimal set that gives a sibling loop the core loops'
semantics:

1. **`tool_loop_response($reply)`** — takes the turn's `HTTP::Response` or the body
   `parse_response` decoded from it, and returns the `Langertha::Response` the core loops use.
   The blocked-prompt check (`_tool_loop_block_reason`) is part of it and needs no hook of its
   own. The decoded-body form leaves the engine's `rate_limit` alone; only an `HTTP::Response`
   updates it.
2. **`tool_loop_calls($reply, $data)`** — the calls one turn runs and the body its assistant echo
   is built from, with k324's truncation handling. `$data` defaults to `$reply->raw`.

`_tool_loop_response` and `_tool_loop_calls` stay as private aliases that delegate to the public
names, so an engine overriding the public method is honoured on both. Core's `Langertha::Chat`
loops still call the private names; that is behavior-neutral.

The raw readers are brought in line with the same parser. `response_text_content` returns the
`content` `chat_response` builds from the body (k338), and `response_tool_calls` returns, as raw
structures, exactly the calls `tool_loop_response` puts on `tool_calls`: a located structure that
parses to no `ToolCall` is left out, and on a hermes engine the native calls the parser found are
returned as `{ name, arguments }`. Neither reader croaks; a body `chat_response` rejects falls back
to the per-format read. Engines whose own `chat_response` needs the per-format read (AKI native)
call the private `_raw_text_content` / `_raw_tool_calls`, so the readers cannot recurse.

The contract is pinned in `t/46_public_tool_loop_hooks.t` and `t/60_response_text_content.t`.
The raider-side migration is ticket 85 on the langertha-raider karr board.

## Update (k407, k410 — plugin hooks for streamed and failed calls, and the tool call on the tool hooks)

Until k407, `Langertha::Chat` fired `plugin_after_llm_response` only for the non-streaming
methods, and nothing told a plugin that a call failed. A tracing plugin (ADR 0041, and
`Plugin::Langfuse`) left no record of a streamed call or of a failure. The tool hooks got only
the name and arguments, so a plugin could not pair `plugin_before_tool_call` with
`plugin_after_tool_call` when two calls shared a name or another plugin renamed or skipped one.

The plugin hook surface grows by one hook and three optional trailing arguments:

1. **`plugin_llm_call_failed($error, $iteration, $call)`** (`Langertha::Plugin`, default does
   nothing). `Langertha::Chat` fires it when an LLM call fails between `plugin_before_llm_call`
   and the end of the `plugin_after_llm_response` hooks: the request cannot be sent, the server
   answers with an error status, the answer cannot be read or reports an error, the stream
   breaks, the caller's stream callback dies, or an after-hook dies. The rules:
   - **Each plugin hears of a call once.** The hook runs only on plugins whose
     `plugin_after_llm_response` has not finished for that call. When the second plugin's
     after-hook dies, the first plugin (already told how the call ended) is not told again; the
     second and those after it are. The bookkeeping is keyed by the `$call` HashRef itself
     (a field hash, dropped with it), so it needs no call id.
   - **The caller's error propagates unchanged:** the same exception, and on the `_f` methods
     the same failed Future, category and details included.
   - **A hook never masks it.** A plugin that dies or returns a failed Future is warned about and
     the next plugin still runs; a returned Future is waited for, and a cancelled one counts as
     finished. A cancel of the call itself is not a failure. A plugin that dies in
     `plugin_before_llm_call` or in a tool hook is not a failed LLM call.
2. **`plugin_after_llm_response($data, $iteration, $call)`** gets an optional `$call` HashRef:
   `stream` (true for the streaming methods) and `http_response` (the `HTTP::Response`, without
   the streamed body on the realtime method). A stream fires the hook **once, after it ended**,
   with one `Langertha::Response` aggregated from the chunks (text, thinking, tool calls, model,
   finish reason, usage when sent, timing). The chunks have already gone to the caller's
   callback, so a hook's rewrite reaches only the text the method returns. A stream that cannot
   be read into a `Response` is passed as its text alone: observability never fails the call.
   With no plugins composed, the stream is not aggregated at all.
3. **`plugin_before_tool_call($name, $input, $call)` / `plugin_after_tool_call($name, $input,
   $result, $call)`** get an optional `$call` HashRef `{ id }` (the tool call id the model sent,
   an empty string when the provider sends none). It is **one HashRef per tool call, the same for
   every plugin and both hooks**, and not part of the pipeline's return value, so whatever an
   earlier plugin returns, a later one can still pair its two hooks by it.
4. **`Langertha::Chat::simple_chat_stream_realtime_f`** is public: the async streaming method on
   the plugin-hosting chat wrapper, mirroring `Role::Chat::simple_chat_stream_realtime_f`, and the
   one that measures `ttft_seconds`.

Why trailing and optional: a host that passes no `$call` (langertha-raider today) calls the hooks
with the two or three arguments they always had, and a plugin written for those keeps working; a
missing `$call` means "not streamed" and "pair by name". The new hook defaults to a no-op, so
existing plugins need no change. "Once per call" was chosen over "every plugin on every failure"
because a tracing plugin whose after-hook finished has already closed its span as a success;
telling it again would make it record one call twice.

Accepted trade-off: an error the tool loops detect in a 200 body *after* all after-hooks
finished (the croak of `tool_loop_response`, k341 Update above) reaches no
failure hook, since every plugin has already heard of the call. A trace then shows that call as a
success; k415 tracks it. langertha-raider fires neither the failure hook nor the `$call`
arguments yet; k414 is that sibling's migration.

The contract is pinned in `t/45_chat_stream_hooks_transport.t`, `t/46_chat_llm_call_failed_hook.t`
and `t/46_tool_hook_call_arg.t`.

## Update (k411 — `Usage` records which counts were reported)

`from_raw` returning `undef` (above) tells "no usage reported" from "zero tokens" for a whole
body, but a body can report some counts and not others, and the numeric accessors returned `0`
for both. An exporter (ADR 0041's `usage_attributes`) then sent a measured-looking `0`.

`Langertha::Usage` gains **`has_input_tokens`**, **`has_output_tokens`** and
**`has_total_tokens`**: true when the count was given (found on the wire by `from_hash` /
`from_raw`, or passed to `new`), false when it is the default. A reported zero is reported.
`has_total_tokens` is also true when the total is the sum of two reported counts, not when one
half of the sum is missing. The parsers no longer turn a missing count into a reported `0`. The
numeric accessors are unchanged and still return `0`, so callers that only add up see no
difference.

Gemini is the one exception, at the universal door (ADR 0018 tier 1) and in `Engine::Gemini`
alike: its proto3 JSON leaves out a count that is zero, so **inside a present `usageMetadata`
block a missing count is a reported `0`** (a blocked prompt has `totalTokenCount` but no
`candidatesTokenCount`: output is a reported `0`). Only a missing block leaves Gemini's counts
unreported. `from_raw` marks a block found under `usageMetadata` as Gemini's; `from_hash` treats a
block with any Gemini camelCase key the same way.

This stays here rather than on ADR 0031: 0031 decides what `input_tokens` *means* (with or
without the cache); this decides whether the count was *reported*, the distinction this ADR
introduced with `from_raw`. Pinned in `t/91_usage_reported.t`.
