# Langertha — CLAUDE.md

Canonical instruction file for the Langertha repo. Langertha is a Perl LLM framework supporting
~25 engines via composable Moose roles: chat, tool calling (MCP), streaming, embeddings,
transcription, structured output, and an autonomous agent (Raider).

This distribution ships its own agent skills (`.claude/skills/`), agents (`.claude/agents/`),
and house rules (`.claude/rules/`). The engineering discipline, delegation, coordination,
public-issue and release rules live in `.claude/rules/langertha-rules.md` — imported here so
they load for the main agent and every subagent.

@.claude/rules/langertha-rules.md

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself — principle
and lane are in the house rules. Agents in this repo:

| Task | Agent |
|---|---|
| Implement / refactor / debug / test behavior-relevant code | `langertha-worker` (default) |
| Backfill & record architecture decisions in `docs/adr/` | `langertha-adr-auditor` |
| Validate / red-team a plan against LLM-provider reality; market & provider Sonderheiten | `langertha-llm-advisor` |

The natural chain: orchestrator plans → `langertha-llm-advisor` validates it against provider
reality → `langertha-worker` implements → `langertha-adr-auditor` records the decision.

The agents carry their skills via `briefing.skills` (see `.claude/agents/`); the main agent
delegates rather than loading them. Skill sources live under `.claude/skills/`.

## Coordination & public issues

- **karr** (`refs/karr/*`, board state in git refs) is the internal AI work board — always in
  scope, just use it (`karr board`, `karr list`, `karr create …`). One board, single repo.
- **GitHub issues** (`gh`, `github.com/Getty/langertha`) are the **public** tracker — real
  users' bug reports. **Never touch without explicit instruction.** Guardrails: house rules +
  skill `langertha-github-issues`.

## Architecture decisions (ADRs)

`docs/adr/` records the WHY behind architecturally-significant decisions so it survives
refactors:

- **0001** — tool wire-translation routes through value objects keyed by `tool_wire_format`
- **0002** — engine capabilities derive from the composed role inventory
- **0003** — `Response.tool_calls` is the single source of truth for emitted tool calls
- **0004** — provider-specific wire extras extend the request body / `Response` (no `extra_body` side-channel)
- **0005** — structured output and forced tool calling are unified; `chat_f` auto-rewrites per capability
- **0006** — engine inheritance encodes the wire dialect; roles encode capabilities
- **0007** — Raider keeps a never-compressed session archive plus an auto-compressed working history
- **0008** — Raider exposes its control surface to the model as virtual self-tools
- **0009** — request-side control params (reasoning effort, prompt caching) as a per-concern wire-format quartet
- **0010** — canonical inbound `ToolCall->extract($fmt,$data)` + symmetric `ToolChoice->to($fmt)` complete the value-object seam

Format + when-to-write: skill `langertha-adr`; backfill new ones via the `langertha-adr-auditor`
agent. `CONTEXT.md` is the domain language for the tools lane (canonical terms, not a decision
log) — ADRs link to it, they don't restate it.

## Build & test

Uses the `[@Author::GETTY]` Dist::Zilla plugin bundle.

```bash
dzil test                       # Build and test (recursive)
prove -lr t/                    # Run tests directly (recursive — see note)
prove -lv t/60_tool_calling.t   # Single test, verbose
```

**Verify recursively.** `prove -l t/` is NOT recursive and silently skips `t/` subdir tests.
Use `prove -lr t/` or `dzil test`. Live tests (`t/80-86*`) are gated on
`TEST_LANGERTHA_<ENGINE>_API_KEY` and skip without keys (and cost real money — be selective).
Test framework: `Test2::Bundle::More`. `dzil release` is forbidden without explicit go-ahead
(house rules).

## OOP / Async / MCP / POD

- **Moose exclusively.** Every class ends with `__PACKAGE__->meta->make_immutable`.
- **`Future::AsyncAwait`** (>= 0.66) for all async methods; **IO::Async** event loop.
- **MCP**: `Net::Async::MCP` (client), `MCP::Server` (tool definitions, `inputSchema` camelCase).
- **POD**: `@Author::GETTY` PodWeaver. `# ABSTRACT:` required on every `.pm`; inline `=attr`,
  `=method`, `=seealso`. Use the `pod-writer` agent for documentation.

## Architecture

### Engine hierarchy (`lib/Langertha/Engine/`)

```
Engine::Remote              url required, JSON + HTTP
  │
  ├── Engine::AnthropicBase /v1/messages format, x-api-key auth, SSE streaming
  │     ├── Anthropic       Claude models, thinking blocks, tool_use
  │     ├── MiniMaxAnthropic MiniMax via legacy /anthropic shim endpoint
  │     ├── MoonshotAnthropic Moonshot Kimi via /anthropic shim endpoint
  │     └── LMStudioAnthropic LM Studio Anthropic-compatible endpoint
  │
  ├── Engine::OpenAIBase    /chat/completions format, Bearer auth, SSE streaming
  │     │  Cloud providers (url has default, api_key from env)
  │     ├── OpenAI          gpt-4o, embeddings, whisper transcription, structured output
  │     ├── DeepSeek        deepseek-chat/reasoner, structured output
  │     ├── Groq            ultra-fast inference, whisper transcription, structured output
  │     ├── XAI             xAI Grok (grok-4.3), 1M context, agentic tool calling
  │     ├── Mistral         EU-hosted, embeddings, structured output
  │     ├── MiniMax         Shanghai (default), ~200K context, M3
  │     ├── Moonshot        Moonshot Kimi (kimi-k2.6), multimodal, 256K context
  │     ├── NousResearch    Hermes models, <tool_call> XML tool format
  │     ├── Cerebras        wafer-scale chips, fastest inference
  │     ├── OpenRouter      meta-provider, 300+ models, provider/model format
  │     ├── Replicate       thousands of open-source models, owner/model format
  │     ├── HuggingFace     Inference Providers, org/model format
  │     ├── Perplexity      search-augmented, citations — NO tool calling
  │     ├── AKIOpenAI       EU/Germany, GDPR-compliant
  │     ├── TSystems        T-Systems AIFS / LLM Hub, T-Cloud Germany + EU hyperscaler models
  │     ├── Scaleway        EU-hosted Generative APIs, drop-in OpenAI replacement
  │     │  Self-hosted (url required, no api_key)
  │     ├── OllamaOpenAI    Ollama /v1 endpoint, embeddings
  │     ├── vLLM            high-throughput inference, single-model server
  │     ├── SGLang          SGLang OpenAI-compatible server, fast structured output
  │     ├── LlamaCpp        llama.cpp server, embeddings
  │     └── LMStudioOpenAI  LM Studio's OpenAI-compatible endpoint
  │
  ├── Engine::TranscriptionBase  Transcription-only OpenAI-shape base (no chat/tools)
  │     └── Whisper         self-hosted faster-whisper-server etc.
  │
  │  Non-OpenAI formats (own request/response handling)
  ├── Gemini                ?key= auth, functionDeclarations, thought parts
  ├── Ollama                native /api/chat, NDJSON streaming, OpenAPI spec
  ├── AKI                   key-in-body auth, EU/Germany, /api/call/{model}
  └── LMStudio              LM Studio native API (non-OpenAI/non-Anthropic)
```

- **LMStudio family** — `LMStudio` (native), `LMStudioOpenAI` (OpenAI-compatible),
  `LMStudioAnthropic` (Anthropic-compatible). Pick whichever the server serves.
- **AKI family** — `AKI` (official native API, changes often) vs `AKIOpenAI` (more stable
  OpenAI-compatible, sometimes lacks features). Both provided; no endorsement.
- **Whisper / `->whisper`** — `Whisper` extends `TranscriptionBase` (transcription only, no
  chat/tools/embeddings). The `whisper` attribute on `OpenAI` returns a `TranscriptionBase`
  pre-configured with the parent's `api_key`/`url`.

### Roles (`lib/Langertha/Role/`)

- **Capabilities** — `engine_capabilities` registry + `supports($cap)`; flags derive from the
  composed role inventory (`%ROLE_TO_CAPS`), engines correct wire reality via
  `around engine_capabilities`. → **ADR 0002**.
- **Chat** — sync/async chat (`simple_chat`, `simple_chat_f`); `chat_f(messages, tools,
  tool_choice, response_format)` for single-turn structured calls (auto-rewrites per wire reality).
- **Tools** — MCP tool-calling loop (`chat_with_tools_f`, `mcp_servers`); thin tag-driven
  orchestration over the value objects. → **ADR 0001**.
- **HermesTools** — `<tool_call>` XML tag names + prompt template for the `hermes` wire format.
- **Streaming** — SSE / NDJSON streaming. **Embedding**, **Transcription**, **ImageGeneration**.
- **HTTP** (sync + async via IO::Async) · **JSON** (`$self->json`) · **OpenAICompatible** ·
  **OpenAPI** (spec validation) · **ThinkTag** (`<think>` filtering) · **Langfuse** (observability).
- **SystemPrompt**, **Temperature**, **ResponseSize**, **ContextSize**, **Seed**,
  **ResponseFormat** (`decode_loose_json`), **Models**, **ParallelToolUse**.
- **ReasoningEffort** (`reasoning_effort`) · **PromptCache** (`prompt_cache` / `prompt_cache_key`)
  — request-side controls serialized per-wire by value objects, keyed by per-concern
  `reasoning_wire_format` / `cache_wire_format` (separate from `tool_wire_format`). → **ADR 0009**.

### Core classes

- **Langertha::Response** — LLM response (stringifies to content). `tool_calls` is
  `ArrayRef[Langertha::ToolCall]` — single source of truth, native + synthetic. → **ADR 0003**.
- **Langertha::Tool / ToolCall / ToolResult / ToolChoice** — canonical tool wire-translation
  value objects, dispatched by `tool_wire_format`. Definitions, calls, result blocks, and
  selection policy each own their per-format serializers. → **ADR 0001**, `CONTEXT.md`.
- **Langertha::Reasoning / PromptCache** — request-side control value objects (reasoning effort,
  prompt caching); per-format serializers dispatched by `reasoning_wire_format` /
  `cache_wire_format`. → **ADR 0009**.
- **Langertha::Stream / Stream::Chunk** — streaming iteration; `Stream::Chunk` carries
  `tool_calls`, aggregated by `Role::Chat::aggregate_tool_calls`.
- **Langertha::Content::Image** — provider-agnostic vision input.
- **Langertha::Raider / Raider::Result** — autonomous agent (below).

### Tool & structured-output flow

`tool_wire_format` (`openai` | `anthropic` | `gemini` | `ollama` | `responses` | `hermes`) keys
all tool wire-translation through the value objects; `chat_f` auto-rewrites between
tools / `tool_choice` / `response_format` when the wire reality demands it (e.g. Perplexity →
`response_format=json_schema` + synthetic ToolCall; Anthropic structured output → synth tool +
forced choice). Every case lands as a `Langertha::ToolCall` on `Response.tool_calls`. The full
decision matrix, the per-provider wire payloads, and the resolved vocabulary (Result envelope,
Assistant echo) live in **`CONTEXT.md`** and **ADRs 0001–0003, 0005** — read those before changing
the seam, and reconcile any drift (open karr tickets #1, #2).

## Raider (autonomous agent)

`Langertha::Raider` wraps an engine with conversation history, MCP tools, and a multi-turn
tool-calling loop.

- **History** — conversation history (user + final assistant) persisted across raids; **session
  history** (full archive incl. tool calls) never compressed; **auto-compression** summarizes
  when a token threshold is exceeded; **embedding search** over session history (cosine).
- **Metrics** (raids, iterations, tool calls, timing) · **Langfuse** traces/spans/generations.
- **Hermes tool calling** for models without native support.
- **Mid-raid injection** — `inject()` and `on_iteration` callback.
- **Self-tools** (virtual, `raider_mcp => 1`): `raider_ask_user`, `raider_pause`,
  `raider_abort`, `raider_wait`, `raider_wait_for`, `raider_session_history`,
  `raider_manage_mcps`, `raider_switch_engine`.
- **Inline tools** (`tools => [...]`) · **MCP catalog** (`mcp_catalog`) · **Engine catalog**
  (`engine_catalog`, runtime engine switching).
- **Result objects** — `raid_f` returns `Langertha::Raider::Result` (stringifies for back-compat);
  `respond_f` resumes after a question/pause.

```perl
my $result = await $raider->raid_f(@messages);   # Result (sync wrapper: ->raid)
if ($result->is_question) { my $next = await $raider->respond_f($answer); }

$raider->switch_engine('smart');     # programmatic engine switch (NOT LLM-controlled)
$raider->reset_engine;               # back to default
my $info = $raider->engine_info;     # { name, class, model }
```

## Skills map

| Need | Skill |
|---|---|
| Engine creation, Raider, MCP, plugin pipeline (architecture) | `perl-ai-langertha` |
| Moose patterns (attributes, roles, BUILD, immutability) | `perl-moose` |
| Async (IO::Async, Future, Future::AsyncAwait lifecycle) | `perl-io-async-future` |
| dist.ini / `[@Author::GETTY]` bundle, POD conventions, next-version | `perl-release-author-getty`, `perl-release-dist-ini` |
| Commit message conventions | `git-commit-style` |
| ADR format + backfill method | `langertha-adr` |
| GitHub public issues (`gh`) guardrails | `langertha-github-issues` |
| karr board commands | `karr` |
