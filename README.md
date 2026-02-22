```
 __                              __   __
|  .---.-.-----.-----.-----.----|  |_|  |--.---.-.
|  |  _  |     |  _  |  -__|   _|   _|     |  _  |
|__|___._|__|__|___  |_____|__| |____|__|__|___._|
---------------|_____|----------------------------
```

<p align="center">
  <em>The clan of fierce vikings with axes and shields to AId your rAId</em>
</p>

<p align="center">
  <a href="https://metacpan.org/pod/Langertha"><img src="https://img.shields.io/cpan/v/Langertha?style=flat-square&label=CPAN" alt="CPAN"></a>
  <a href="https://github.com/Getty/langertha/actions"><img src="https://img.shields.io/github/actions/workflow/status/Getty/langertha/test.yml?style=flat-square&label=CI" alt="CI"></a>
  <a href="https://metacpan.org/pod/Langertha"><img src="https://img.shields.io/cpan/l/Langertha?style=flat-square" alt="License"></a>
  <a href="https://discord.gg/Y2avVYpquV"><img src="https://img.shields.io/discord/1095536723398238308?style=flat-square&label=Discord" alt="Discord"></a>
</p>

---

**Langertha** is a unified Perl interface for LLM APIs. One API, many providers. Supports chat, streaming, embeddings, transcription, MCP tool calling, and dynamic model discovery.

## Supported Providers

| Provider | Chat | Streaming | Tools (MCP) | Embeddings | Transcription | Models API |
|----------|:----:|:---------:|:-----------:|:----------:|:-------------:|:----------:|
| [OpenAI](https://platform.openai.com/) | :white_check_mark: | :white_check_mark: | :white_check_mark: | :white_check_mark: | :white_check_mark: | :white_check_mark: |
| [Anthropic](https://console.anthropic.com/) | :white_check_mark: | :white_check_mark: | :white_check_mark: | | | :white_check_mark: |
| [Gemini](https://ai.google.dev/) | :white_check_mark: | :white_check_mark: | :white_check_mark: | | | :white_check_mark: |
| [Ollama](https://ollama.com/) | :white_check_mark: | :white_check_mark: | :white_check_mark: | :white_check_mark: | | :white_check_mark: |
| [Groq](https://console.groq.com/) | :white_check_mark: | :white_check_mark: | :white_check_mark: | | :white_check_mark: | :white_check_mark: |
| [Mistral](https://console.mistral.ai/) | :white_check_mark: | :white_check_mark: | :white_check_mark: | | | :white_check_mark: |
| [DeepSeek](https://platform.deepseek.com/) | :white_check_mark: | :white_check_mark: | :white_check_mark: | | | :white_check_mark: |
| [vLLM](https://docs.vllm.ai/) | :white_check_mark: | :white_check_mark: | :white_check_mark: | | | |
| [Whisper](https://github.com/fedirz/faster-whisper-server) | | | | | :white_check_mark: | |

## Quick Start

```bash
cpanm Langertha
```

```perl
use Langertha::Engine::OpenAI;

my $openai = Langertha::Engine::OpenAI->new(
    api_key => $ENV{OPENAI_API_KEY},
    model   => 'gpt-4o-mini',
);

print $openai->simple_chat('Hello from Perl!');
```

## Usage Examples

### Cloud APIs

```perl
use Langertha::Engine::Anthropic;

my $claude = Langertha::Engine::Anthropic->new(
    api_key => $ENV{ANTHROPIC_API_KEY},
    model   => 'claude-sonnet-4-6',
);
print $claude->simple_chat('Generate Perl Moose classes for GeoJSON.');
```

```perl
use Langertha::Engine::Gemini;

my $gemini = Langertha::Engine::Gemini->new(
    api_key => $ENV{GEMINI_API_KEY},
    model   => 'gemini-2.5-flash',
);
print $gemini->simple_chat('Explain quantum computing.');
```

### Local Models with Ollama

```perl
use Langertha::Engine::Ollama;

my $ollama = Langertha::Engine::Ollama->new(
    url   => 'http://localhost:11434',
    model => 'llama3.3',
);
print $ollama->simple_chat('Do you wanna build a snowman?');
```

### Self-hosted with vLLM

```perl
use Langertha::Engine::vLLM;

my $vllm = Langertha::Engine::vLLM->new(
    url   => $ENV{VLLM_URL},
    model => 'meta-llama/Llama-3.3-70B-Instruct',
);
print $vllm->simple_chat('Hello!');
```

## Streaming

Real-time token streaming with callbacks, iterators, or async/await:

```perl
# Callback
$engine->simple_chat_stream(sub {
    print shift->content;
}, 'Write a poem about Perl');

# Iterator
my $iter = $engine->simple_chat_stream_iterator('Tell me a story');
while (my $chunk = $iter->next) {
    print $chunk->content;
}

# Async/await with real-time streaming
use Future::AsyncAwait;

my ($content, $chunks) = await $engine->simple_chat_stream_realtime_f(
    sub { print shift->content },
    'Explain monads'
);
```

## MCP Tool Calling

Langertha integrates with [MCP](https://modelcontextprotocol.io/) (Model Context Protocol) servers via [Net::Async::MCP](https://metacpan.org/pod/Net::Async::MCP). LLMs can discover and invoke tools automatically.

```perl
use IO::Async::Loop;
use Net::Async::MCP;
use Future::AsyncAwait;

my $loop = IO::Async::Loop->new;

# Connect to an MCP server (in-process, stdio, or HTTP)
my $mcp = Net::Async::MCP->new(
    command => ['npx', '@anthropic/mcp-server-web-search'],
);
$loop->add($mcp);
await $mcp->initialize;

# Any engine, same API
my $engine = Langertha::Engine::Anthropic->new(
    api_key     => $ENV{ANTHROPIC_API_KEY},
    model       => 'claude-sonnet-4-6',
    mcp_servers => [$mcp],
);

my $response = await $engine->chat_with_tools_f(
    'Search the web for Perl MCP modules'
);
say $response;
```

The tool-calling loop runs automatically:

1. Gathers available tools from all configured MCP servers
2. Sends chat request with tool definitions to the LLM
3. If the LLM returns tool calls, executes them via MCP
4. Feeds tool results back to the LLM and repeats
5. Returns the final text response

Works with **all engines** that support tool calling (see table above).

## Async/Await

All operations have async variants via [Future::AsyncAwait](https://metacpan.org/pod/Future::AsyncAwait):

```perl
use Future::AsyncAwait;

async sub main {
    my $response = await $engine->simple_chat_f('Hello!');
    say $response;
}

main()->get;
```

## Embeddings

```perl
use Langertha::Engine::OpenAI;

my $openai = Langertha::Engine::OpenAI->new(
    api_key => $ENV{OPENAI_API_KEY},
);

my $embedding = $openai->simple_embedding('Some text to embed');
# Returns arrayref of floats
```

Also supported by Ollama (e.g. `mxbai-embed-large`).

## Transcription (Whisper)

```perl
use Langertha::Engine::Whisper;

my $whisper = Langertha::Engine::Whisper->new(
    url => $ENV{WHISPER_URL},
);
print $whisper->simple_transcription('recording.ogg');
```

OpenAI and Groq also support transcription via their Whisper endpoints:

```perl
my $openai = Langertha::Engine::OpenAI->new(
    api_key => $ENV{OPENAI_API_KEY},
);
print $openai->simple_transcription('recording.ogg');
```

## Dynamic Model Discovery

Query available models from any provider API:

```perl
my $models = $engine->list_models;
# Returns: ['gpt-4o', 'gpt-4o-mini', 'o1', ...]

my $models = $engine->list_models(full => 1);       # Full metadata
my $models = $engine->list_models(force_refresh => 1); # Bypass cache
```

Results are cached for 1 hour (configurable via `models_cache_ttl`).

## Testing

```bash
# Run all unit tests
prove -l t/

# Run mock tool calling tests (no API keys needed)
prove -l -It/lib t/64_tool_calling_ollama_mock.t

# Run live integration tests
TEST_LANGERTHA_OPENAI_API_KEY=...    \
TEST_LANGERTHA_ANTHROPIC_API_KEY=... \
TEST_LANGERTHA_GEMINI_API_KEY=...    \
prove -l t/80_live_tool_calling.t

# Ollama with multiple models
TEST_LANGERTHA_OLLAMA_URL=http://localhost:11434     \
TEST_LANGERTHA_OLLAMA_MODELS=qwen3:8b,llama3.2:3b   \
prove -l t/80_live_tool_calling.t
```

## Examples

See the [`ex/`](ex/) directory for runnable examples:

| Example | Description |
|---------|-------------|
| `synopsis.pl` | Basic usage with multiple engines |
| `streaming_callback.pl` | Real-time streaming with callbacks |
| `streaming_iterator.pl` | Streaming with iterator pattern |
| `streaming_future.pl` | Async streaming with Futures |
| `async_await.pl` | Async/await patterns |
| `mcp_inprocess.pl` | MCP tool calling with in-process server |
| `mcp_stdio.pl` | MCP tool calling with stdio server |
| `embedding.pl` | Text embeddings |
| `transcription.pl` | Audio transcription with Whisper |
| `structured_output.pl` | Structured/JSON output |

## Community

- **CPAN**: [Langertha on MetaCPAN](https://metacpan.org/pod/Langertha)
- **GitHub**: [Getty/langertha](https://github.com/Getty/langertha) - Issues & PRs welcome
- **Discord**: [Join the community](https://discord.gg/Y2avVYpquV)
- **IRC**: `irc://irc.perl.org/ai`

## License

This is free software licensed under the same terms as Perl itself (Artistic License / GPL).

---

> **THIS API IS WORK IN PROGRESS**
