# Public hooks for langertha-raider (karr k190 + k192)

Date: 2026-09-25 · Status: design · Tickets: k190, k192 · Related: ADR 0026, ADR 0027

## Problem

langertha-raider (sibling dist, `requires 'Langertha'`) reaches into three kinds of
core privates and re-implements usage parsing three times. Core must offer small public
names for exactly what raider needs, without depending on raider (ADR 0026) and without
promising an IO::Async loop (IO::Async is only a `recommends` since k188 / ADR 0027).

## Inventory (langertha-raider @ f39ad50, read-only)

Line numbers drifted from the ticket text (858/1560/1738/1916/2091 → below).

### `_async_http` (Role::AsyncHTTP)

| Site | Call | Needs |
|---|---|---|
| `lib/Langertha/Raider.pm:859` (`compress_history_f`) | `$engine->_async_http->do_request(request => $request)` | send a prepared `HTTP::Request`, get `Future<HTTP::Response>` |
| `lib/Langertha/Raider.pm:1733` (`raid_f` loop) | `$engine->_async_http->do_request(request => $request)` | same; checks `is_success` itself |
| `lib/Langertha/Raider.pm:1555` (`_ensure_inline_mcp`) | `$self->engine->_async_http->loop->add($mcp)` | **an IO::Async loop** to add a `Net::Async::MCP` notifier to |
| `lib/Langertha/Raider.pm:1911` (`raid_f`, self-tool `wait`) | `$engine->_async_http->loop` then `->delay_future(after => N)` | **a timer** |
| `lib/Langertha/Raider.pm:2086` (`respond_f` continuation, `wait`) | same as 1911 | **a timer** |

Raider tests mock the private too: `t/86_raider_self_tools.t:568,759,935`,
`t/87_raider_plugins.t:312` (a mock `_async_http` exposing `loop`).

### `_langfuse_timestamp` (Role::Langfuse)

`lib/Langertha/Raider.pm:1718, 1763, 1821, 1858, 1925, 1951, 1987, 2000, 2129` — nine calls, all
producing `start_time` / `end_time` for `$engine->langfuse_span(...)` /
`langfuse_update_span`. Needs: "now" in the Langfuse ISO-8601 millisecond `Z` format.

### Hand-rolled provider usage parsing

| Site | Shape read | Returns |
|---|---|---|
| `lib/Langertha/Raider.pm:831` `_extract_prompt_tokens` | `usage.{prompt_tokens // input_tokens}`, Gemini `usageMetadata.promptTokenCount` | prompt tokens or `undef` when no usage |
| `lib/Langertha/Raider.pm:1084` `_langfuse_usage` | `usage.{prompt,completion,total}_tokens // input/output`, Gemini `usageMetadata.{prompt,candidates,total}TokenCount` | `{input,output,total}` or `undef` |
| `lib/Langertha/Raider/Plugin/Trace.pm:136` `_extract_usage` | `usage` or `response.usage`, same key pairs | `{prompt,completion,total}` or `undef` |

All three operate on the raw decoded body (`$engine->parse_response($http_response)`),
not on a `Langertha::Response`. Trace only sees `$data` (plugin hook), no engine.

### Other siblings

- **langertha-knarr** (@ 93dbcef): no calls to any engine private (`_async_http`,
  `_async_loop`, `_langfuse_timestamp`); its own `->_` calls are on its own objects.
- **langertha-skeid** (@ 4c8f3ef): no engine-private calls. It parses usage itself
  (`Skeid/Proxy.pm:752`, `Skeid.pm:800`, `Protocol/Ollama/Stream.pm:78`) but on proxied
  wire payloads, with its own cache/cost logic — out of scope here; it could adopt the
  same `Langertha::Usage` door later (not ticketed by this change).

## What core already has

- `Langertha::Usage` (value object) with `from_hash` (OpenAI/Anthropic/Ollama/Responses
  spellings, cache counts) and `from_response` (a `Langertha::Response` or a HashRef with
  a `usage` key; always returns a Usage, zeros when absent).
- It does **not** understand Gemini's camelCase `usageMetadata` (the Gemini engine
  translates it in `chat_response` before `from_hash`), Ollama-native top-level
  `prompt_eval_count`/`eval_count` in a raw body, or a `response.usage` envelope; and it
  cannot say "the body reported no usage" (raider needs that: it must not overwrite
  `_last_prompt_tokens` / send a zero Langfuse usage).

## Design (minimal)

### 1. `$engine->async_request_f($request, %opts)` — Role::AsyncHTTP (k190)

```perl
async sub async_request_f {
  my ($self, $request, %opts) = @_;
  return await $self->_async_http->do_request(request => $request, %opts);
}
```

The public face of the ADR 0027 `do_request` contract: `Future<HTTP::Response>`, 4xx/5xx
**resolve** (caller checks `is_success`), `%opts` passes through (`on_header` for
streaming). Works identically on all three backends (injected, Net::Async::HTTP,
SyncHTTP). It deliberately returns a response, not the backend object, so nothing
beyond `do_request` is exposed. `_async_http` stays the injection seam, unchanged.

### 2. Loop access (k192) — choice **(b): raider brings its own loop**

What raider uses the loop for: (i) `loop->add` of a `Net::Async::MCP` notifier,
(ii) `delay_future` for the `wait` self-tool. Both are IO::Async-specific and raider
already `requires` IO::Async + Net::Async::HTTP + Net::Async::MCP. Option (a) would still
force raider to handle `undef` (injected client, SyncHTTP) — i.e. raider needs its own
loop anyway, so (a) adds public surface without removing that need.

Why (b) is safe: `IO::Async::Loop->new` is IO::Async's magic constructor and returns the
process-wide loop (verified at IO::Async::Loop 0.805: two `->new` are `==`). Core's
default `_async_loop` builder uses exactly that constructor, so a raider that calls
`IO::Async::Loop->new` shares the engine's loop on the default Net::Async::HTTP backend.
On SyncHTTP the loop is simply raider's; `->get` on the pending IO::Async future drives it.

Core change: documentation only, plus one test pinning the documented fact —
Role::AsyncHTTP POD states core offers no loop accessor, that the default backend's
loop is the process `IO::Async::Loop->new`, and that a caller who injects a client on a
different loop must hand that loop to whatever else needs one.

Raider-side (karr ticket): own `loop` (lazy `IO::Async::Loop->new`, overridable
attribute — CLI already holds one); use it at 1555/1911/2086.

### 3. `$engine->langfuse_timestamp` — Role::Langfuse (k190)

Public method, same output as today (`YYYY-MM-DDTHH:MM:SS.mmmZ`, UTC). `_langfuse_timestamp`
remains and delegates to it; internal callers unchanged.

### 4. Normalized usage from a raw body — `Langertha::Usage` (k190)

Extend what exists:

- `from_hash` additionally reads Gemini's camelCase spellings: `promptTokenCount`,
  `candidatesTokenCount`, `totalTokenCount` (value-object inbound door, ADR 0018).
  Existing keys win; cache counts for Gemini are not mapped (Gemini's Response path
  exposes them as `cached_content_token_count`, left as is).
- New class method `Langertha::Usage->from_raw($data)`: locates the usage block in a
  raw decoded provider body — `usage` (OpenAI / Anthropic / Responses / Perplexity),
  `usageMetadata` (Gemini), `response.usage` (Responses event envelope), or top-level
  `prompt_eval_count`/`eval_count` (Ollama native) — and returns a `Langertha::Usage`,
  or **`undef` when the body reports no usage**.
- `from_response` HashRef branch delegates to `from_raw`, falling back to the previous
  behaviour (`from_hash($data->{usage} || {})`), so it still always returns a Usage and
  every previously-handled input is unchanged.

Raider then replaces its three parsers with `Langertha::Usage->from_raw($data)` and reads
`input_tokens` / `output_tokens` / `total_tokens`.

## Out of scope

- No rename/removal of `_async_http`, `_async_loop`, `_langfuse_timestamp` (raider migrates
  later in its own repo).
- No engine-level `response_usage` hook: AKI native (`prompt_length` /
  `num_generated_tokens`) stays engine-scoped in `chat_response`; raider does not see it
  today either. Candidate follow-up if a caller needs it.
- No `to_langfuse_format`; raider maps three accessors.
- No change to knarr/skeid.

## Tests (TDD, contract raider relies on)

- `async_request_f`: resolves with the backend's `HTTP::Response` for an injected client;
  passes `request` + `on_header` through; a 4xx resolves (not fails); works on SyncHTTP.
- `langfuse_timestamp`: format regex, UTC, private alias returns the same shape.
- `Usage->from_raw`: each shape (OpenAI, Anthropic, Gemini, Ollama native, Responses,
  `response.usage`), `undef` for no usage / non-hash; `from_hash` Gemini keys;
  `from_response` unchanged for old inputs and now understands Gemini bodies.
- Loop contract: with Net::Async::HTTP installed, the default backend's loop is
  `IO::Async::Loop->new` (skip otherwise).
