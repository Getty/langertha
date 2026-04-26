---
name: perl-ai-langertha
description: Langertha LLM framework — Engine creation, Raider autonomous agents, MCP tool integration, plugin system
---

<oneliner>
Langertha is a Perl LLM framework with provider-agnostic engines, autonomous Raider agents, MCP tool integration, and a plugin pipeline. Use Future::AsyncAwait for async operations.
</oneliner>

<engines>
## Engine Creation

```perl
# Anthropic
use Langertha::Engine::Anthropic;
my $claude = Langertha::Engine::Anthropic->new(
    api_key       => $ENV{ANTHROPIC_API_KEY},
    model         => 'claude-sonnet-4-6',
    system_prompt => 'You are helpful.',
);

# OpenAI
use Langertha::Engine::OpenAI;
my $gpt = Langertha::Engine::OpenAI->new(
    api_key => $ENV{OPENAI_API_KEY},
    model   => 'gpt-4o',
);

# OpenAI-compatible (Ollama, vLLM, etc.)
my $local = Langertha::Engine::OllamaOpenAI->new(
    url   => 'http://localhost:11434/v1',
    model => 'llama3',
);

# Proxy (HI pattern — proxy handles model routing)
my $proxy = Langertha::Engine::OpenAI->new(
    url     => 'http://127.0.0.1:5000/api/v1',
    model   => $model_key,
    api_key => 'proxy',
);
```

### Available Engine Families

| Base | Engines |
|------|---------|
| AnthropicBase | Anthropic, MiniMaxAnthropic, LMStudioAnthropic |
| OpenAIBase | OpenAI, DeepSeek, Groq, Mistral, Cerebras, OpenRouter, Replicate, HuggingFace, Perplexity, MiniMax, NousResearch, OllamaOpenAI, vLLM, SGLang, LlamaCpp, LMStudioOpenAI, AKIOpenAI, TSystems, Scaleway |
| TranscriptionBase | Whisper (slim, transcription-only — no chat/tools/embeddings) |
| Other | Gemini (Google), Ollama (native), AKI (EU), LMStudio (native) |

`Langertha::Engine::OpenAI` exposes a `whisper` lazy attribute returning a
`TranscriptionBase` bound to the parent's `api_key`/`url` (model `whisper-1`):

```perl
my $text = $openai->whisper->simple_transcription('audio.mp3');
```
</engines>

<capabilities>
## Capability Queries

Every engine reports its capabilities via `Langertha::Role::Capabilities`
(composed by `Role::Chat`, so present on every engine):

```perl
$engine->supports('tool_choice_named')             or die "engine cannot force named tool";
$engine->supports('response_format_json_schema')   # safe to pass json_schema response_format
$engine->supports('streaming')                     # chat_stream_request wired up
$engine->supports('tools_native')                  # accepts a tools array on the wire
$engine->supports('tools_hermes')                  # Hermes XML-tag tool path

my $caps = $engine->engine_capabilities;
# { chat=>1, streaming=>1, tools_native=>1, tool_choice_named=>1,
#   response_format_json_schema=>1, embedding=>1, transcription=>1, ... }
```

The flag set is derived from which capability roles the engine composes
(central role→flag map in `Role::Capabilities`); engines override via
`around engine_capabilities` for wire-reality corrections.
</capabilities>

<chat-f>
## chat_f — Single-Turn with Named Args

For structured single-turn calls (no MCP loop), use `chat_f`:

```perl
my $response = await $engine->chat_f(
    messages       => [ { role => 'user', content => $prompt } ],
    tools          => [ $tool_hash, ... ],            # any provider shape
    tool_choice    => { type => 'tool', name => 'extract' },
    response_format => { type => 'json_schema', json_schema => { ... } },
);

# Read tool calls back uniformly (single source of truth):
my $tc = $response->tool_call;            # first ToolCall
my $tc = $response->tool_call('extract'); # named lookup
my $args = $response->tool_call_args('extract');  # arguments hashref shortcut

$tc->name;
$tc->arguments;
$tc->id;
$tc->synthetic;   # true for forced-name fallbacks (Perplexity etc.)
```

`chat_f` auto-rewrites between forms when wire reality requires it:

- forced named tool on engine without `tool_choice_named` but with
  `response_format_json_schema` → reroutes via response_format and
  loose-parses the result back into a synthetic ToolCall.

For multi-turn MCP tool-calling loops use `chat_with_tools_f` (next
section) — that's the autonomous loop, `chat_f` is single-turn.
</chat-f>

<simple-chat>
## Simple Chat

```perl
# Synchronous
my $response = $engine->simple_chat('What is Perl?');
print $response;  # Stringifies to content

# Async
use Future::AsyncAwait;
my $response = await $engine->simple_chat_f('Tell me a story.');
say $response->model;              # Model name
say $response->prompt_tokens;      # Token usage
say $response->completion_tokens;
say $response->thinking;           # Chain-of-thought (if available)
```

`Langertha::Response` overloads `""` so it works in string contexts.
</simple-chat>

<tool-calling>
## Tool Calling with MCP

### Step 1: Create MCP Server with tools

```perl
use MCP::Server;

my $server = MCP::Server->new(name => 'my-tools', version => '1.0');

$server->tool(
    name        => 'search_files',
    description => 'Search for files matching a pattern',
    input_schema => {
        type       => 'object',
        properties => {
            pattern => { type => 'string', description => 'Glob pattern' },
            path    => { type => 'string', description => 'Directory to search' },
        },
        required => ['pattern'],
    },
    code => sub {
        my ($tool, $args) = @_;
        # $tool is MCP::Tool instance (NOT your class)
        my @files = glob("$args->{path}/$args->{pattern}");
        return $tool->text_result(join("\n", @files));
        # Error: $tool->text_result("Not found", 1);  # is_error=1
    },
);
```

### Step 2: Create MCP client

```perl
use IO::Async::Loop;
use Net::Async::MCP;

my $loop = IO::Async::Loop->new;
my $mcp = Net::Async::MCP->new(server => $server);
$loop->add($mcp);
await $mcp->initialize;
```

### Step 3: Engine with MCP

```perl
my $engine = Langertha::Engine::Anthropic->new(
    api_key     => $ENV{ANTHROPIC_API_KEY},
    model       => 'claude-sonnet-4-6',
    mcp_servers => [$mcp],  # Pass MCP server(s)
);

# One-shot tool calling
my $response = await $engine->chat_with_tools_f('Find all .pm files in lib/');
say $response;
```
</tool-calling>

<raider>
## Raider — Autonomous Agent

```perl
use Langertha::Raider;

my $raider = Langertha::Raider->new(
    engine         => $engine,        # With MCP servers
    mission        => 'You are a code reviewer.',
    max_iterations => 10,             # Max tool rounds per raid
    # Optional:
    max_context_tokens         => 4000,
    context_compress_threshold => 0.75,
    compression_engine         => $cheap_model,
    raider_mcp                 => 1,   # Enable self-tools (ask_user, pause, abort)
    plugins                    => ['Langfuse'],
);

# Raid (autonomous tool-calling loop)
my $result = await $raider->raid_f('Review lib/App.pm');

# Result handling
say $result;                # Stringified response
say $result->is_question;   # Agent asked a question
say $result->is_abort;      # Agent aborted

# Continue conversation (has context from previous raids)
my $r2 = await $raider->raid_f('Now suggest improvements.');

# Respond to question
if ($result->is_question) {
    my $next = await $raider->respond_f('Yes, go ahead.');
}

# History management
$raider->add_history('user', $content);  # Replay from DB
$raider->clear_history;                  # Reset

# Metrics
my $m = $raider->metrics;
say "Iterations: $m->{iterations}";
say "Tool calls: $m->{tool_calls}";
```

### Raid Loop (simplified)

1. Auto-compress history if context threshold exceeded
2. Gather tools from MCP servers + inline tools + self-tools
3. Build conversation: mission + history + new messages
4. Call LLM with tools
5. If tool calls: execute via MCP, add results to conversation, loop
6. If no tool calls: extract final text, persist to history, return result
7. Max iterations safety limit
</raider>

<plugins>
## Plugin System

```perl
package Langertha::Plugin::MyGuardrails;
use Langertha qw( Plugin );

async sub plugin_before_tool_call {
    my ($self, $name, $input) = @_;
    return if $name eq 'dangerous_tool';  # Skip tool
    return ($name, $input);               # Allow tool
}

async sub plugin_after_raid {
    my ($self, $result) = @_;
    return $result;  # Transform result
}

__PACKAGE__->meta->make_immutable;

# Usage
my $raider = Langertha::Raider->new(
    engine  => $engine,
    plugins => ['MyGuardrails', 'Langfuse'],
);
```

### Plugin Hooks (all async sub)

| Hook | Purpose |
|------|---------|
| `plugin_before_raid(@messages)` | Transform input |
| `plugin_build_conversation(@conv)` | Transform assembled conversation |
| `plugin_before_llm_call(@conv, $iter)` | Transform before each LLM call |
| `plugin_after_llm_response($data, $iter)` | Inspect LLM response |
| `plugin_before_tool_call($name, $input)` | Allow/block tool (empty = skip) |
| `plugin_after_tool_call($name, $input, $result)` | Transform tool result |
| `plugin_after_raid($result)` | Transform final result |
</plugins>

<roles>
## Composable Roles

Engines compose feature roles:

| Role | Feature |
|------|---------|
| `Langertha::Role::Capabilities` | `engine_capabilities` registry + `supports($cap)` |
| `Langertha::Role::Chat` | `simple_chat`, `simple_chat_f`, `chat_f` (named args), `aggregate_tool_calls` |
| `Langertha::Role::Tools` | `chat_with_tools_f` (MCP loop) |
| `Langertha::Role::HermesTools` | XML-tag tool calling for models without native support |
| `Langertha::Role::ParallelToolUse` | `parallel_tool_use` boolean (canonical name) |
| `Langertha::Role::Streaming` | SSE/NDJSON streaming |
| `Langertha::Role::Embedding` | Vector embeddings |
| `Langertha::Role::Transcription` | Audio-to-text |
| `Langertha::Role::ImageGeneration` | Image generation |
| `Langertha::Role::SystemPrompt` | System prompt management |
| `Langertha::Role::Temperature` | Sampling temperature |
| `Langertha::Role::Seed` | Deterministic seed (`seed`, `randomize_seed`) |
| `Langertha::Role::ContextSize` | `context_size` parameter |
| `Langertha::Role::ResponseSize` | `response_size` / max_tokens parameter |
| `Langertha::Role::ResponseFormat` | JSON mode / structured output, plus `$self->decode_loose_json($text)` (overridable) |
| `Langertha::Role::Models` | Model listing |
| `Langertha::Role::Langfuse` | Observability |
| `Langertha::Role::ThinkTag` | Chain-of-thought filtering |

`AnthropicBase`, `Gemini`, and `Ollama` compose `ResponseFormat` and
translate the OpenAI-shape `response_format` hash into their native
mechanism: Anthropic emulates via a synthesized tool + forced
`tool_choice` (then lifts the tool_use input back into Response.content
as JSON); Gemini → `generationConfig.responseSchema`; Ollama →
`format` parameter (string `'json'` or schema HashRef).
</roles>

<value-objects>
## Value Objects

| Class | Purpose |
|-------|---------|
| `Langertha::Tool` | Canonical tool definition. `from_openai/from_anthropic/from_mcp/from_gemini/from_hash` accept any shape; `to_openai/to_anthropic/to_gemini/to_mcp/to_json_schema` emit per-provider wire payloads. |
| `Langertha::ToolChoice` | Canonical tool-selection policy (`auto`/`any`/`none`/`tool`). `to_openai/to_anthropic/to_gemini/to_perplexity` per-provider serializers. |
| `Langertha::ToolCall` | Tool invocation emitted by an LLM. `name`, `arguments`, `id`, `synthetic`. `from_openai/from_anthropic/from_ollama/from_gemini`; `extract($raw)` pulls every call out of any known response shape. |
| `Langertha::Content::Image` | Provider-agnostic vision input. `from_url/from_file/from_data`; `to_openai/to_anthropic/to_gemini`. |
| `Langertha::Response` | LLM response with metadata. Stringifies to `content`. `tool_calls` is `ArrayRef[Langertha::ToolCall]` — single source of truth. |
| `Langertha::Stream::Chunk` | Single streaming chunk. Optional `tool_calls` for engines that emit them mid-stream; `Role::Chat::aggregate_tool_calls(\@chunks)` flattens. |

Use these instead of hand-rolled hashes when normalizing across
providers. `Tool->from_hash` auto-detects MCP camelCase, Anthropic
snake_case, OpenAI envelope, and Gemini-flat shapes.
</value-objects>
