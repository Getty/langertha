---
name: perl-ai-langertha
description: Use when calling an LLM from Perl through Langertha, or building on it from another distribution — engines, chat_f, supports(), tool calling with MCP, Tool/ToolCall/Response value objects, plugins, Langertha::Raider.
---

# Langertha — calling it

Langertha is a Perl LLM framework: one engine class per provider, one canonical API on top.
The autonomous agent (`Langertha::Raider`) is the separate distribution **langertha-raider**.
This skill is the caller's guide; changing core itself is `langertha-internals`.

## Engines

```perl
use Langertha::Engine::Anthropic;
my $claude = Langertha::Engine::Anthropic->new(
    api_key       => $ENV{ANTHROPIC_API_KEY},  # cloud engines also read LANGERTHA_<NAME>_API_KEY
    system_prompt => 'You are helpful.',
    # model => '...',   # omit for the engine's default_model
);

# Self-hosted: url required, no api_key
my $local = Langertha::Engine::OllamaOpenAI->new( url => 'http://localhost:11434/v1' );

# Proxy (an OpenAI-compatible proxy routes the model)
my $proxy = Langertha::Engine::OpenAI->new(
    url => 'http://127.0.0.1:5000/api/v1', model => $model_key, api_key => 'proxy' );
```

- Pick the engine by the wire the endpoint speaks: `OpenAIBase` (`/chat/completions`),
  `AnthropicBase` (`/v1/messages`), `TranscriptionBase` (transcription only, e.g. `Whisper`),
  `Remote` for own formats (Gemini, Ollama native, AKI, LMStudio native, Perplexity). Full
  catalogue: `perldoc Langertha` → *Engine Modules*.
- `OpenAI` has a lazy `whisper` attribute: `$openai->whisper->simple_transcription('audio.mp3')`.
- `chat_model` (used by chat and `supports()`) defaults to `model`. Check `$response->model`
  when it matters which model answered — some shims substitute silently.

## Sync and `_f`

```perl
my $r = $engine->simple_chat('What is Perl?');   # blocking; Response stringifies to content
use Future::AsyncAwait;
$r = await $engine->simple_chat_f('Tell me a story.');
```

- `IO::Async` and `Net::Async::HTTP` are `recommends`, not `requires`. Without them every `_f`
  method still returns a `Future` but runs **synchronously** over LWP (warns once per process),
  so futures awaited "in parallel" run one after another. Install both for real concurrency.
- `simple_chat*` take messages only: a trailing `reasoning_effort => 'high'` is sent as user
  text (Langertha warns). Pass controls to `chat_f` or set them on the engine.

## Capabilities — `supports()`

`$engine->supports('tool_choice_named')`; `$engine->engine_capabilities` is the HashRef.

- The answer is evaluated for the current `chat_model` — the same engine class can answer
  differently for another model. Query it on the configured engine, not the class.
- Some combinations croak before the request instead of returning a provider 400:
  `tools` + a `response_format` on Groq and Cerebras (Groq also rejects `json_schema` with
  streaming). Run the tools, then a second structured-output turn.

## `chat_f` — single turn, named args

```perl
my $response = await $engine->chat_f(
    messages        => [ { role => 'user', content => $prompt } ],
    tools           => [ $tool_hash, ... ],          # any provider shape
    tool_choice     => { type => 'tool', name => 'extract' },
    response_format => { type => 'json_schema', json_schema => { ... } },
    reasoning_effort => 'high',                      # per-request control
);
my $args = $response->tool_call_args('extract');   # HashRef
my $tc   = $response->tool_call('extract');        # or ->tool_call for the first
# $tc->name, ->arguments, ->id, ->synthetic (true when chat_f rewrote the request)
```

- Every path lands on `Response.tool_calls` as `Langertha::ToolCall`, so read it the same way
  on every provider. `chat_f` rewrites the request per wire (e.g. forced `tool_choice` →
  `json_schema` + `synthetic` call); the matrix is in `references/chat-f-wire-matrix.md`.
- `chat_f` is one turn; multi-turn MCP tool loops are `chat_with_tools_f`.
- Use the engine's own `$engine->tool_wire_format` when you need a `$fmt` for value objects.

## Response and request controls — the traps

- A Response has `content`, `model`, `finish_reason`, `thinking`, `citations`, `tool_calls`,
  `usage` (`Langertha::Usage`), `rate_limit`, `created`, timing. Test with the `has_*`
  predicates before reading optional fields; `rate_limit` fields are `undef` when the wire
  sent nothing.
- Controls (`reasoning_effort`, `prompt_cache`, `temperature`, …) go on the engine or per
  request through `chat_f`. `reasoning_effort` values the wire cannot take are dropped.
- A 200 does not prove a prompt-cache write; check `usage`.
- You bring the MCP client: `mcp_servers` takes any `Net::Async::MCP`-compatible client
  (`list_tools` + `call_tool`); Langertha does not depend on one.

## Where the details are

| Need | Read |
|---|---|
| What `chat_f` sends per wire (tools / `tool_choice` / `response_format` matrix), Perplexity / `OpenAIResponses` limits | `references/chat-f-wire-matrix.md` |
| All `supports()` flag names; `reasoning_effort`, prompt caching, self-hosted knobs, other request controls | `references/capabilities-and-controls.md` |
| Response fields (`usage`, `rate_limit`, `created`, timing); `Tool` / `ToolCall` / `ToolChoice` / `ToolResult`, `Content::Image`, `CallResult` | `references/value-objects.md` |
| MCP server + `chat_with_tools_f` example; writing and attaching plugins, hook table | `references/mcp-and-plugins.md` |
| `Langertha::Raider`: missions, questions back, history, metrics | `references/raider.md` |
