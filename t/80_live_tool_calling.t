#!/usr/bin/env perl
# ABSTRACT: Live integration test for MCP tool calling against real APIs

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;

BEGIN {
  my @available;
  push @available, 'anthropic' if $ENV{TEST_LANGERTHA_ANTHROPIC_API_KEY};
  push @available, 'openai'    if $ENV{TEST_LANGERTHA_OPENAI_API_KEY};
  push @available, 'gemini'    if $ENV{TEST_LANGERTHA_GEMINI_API_KEY};
  push @available, 'groq'      if $ENV{TEST_LANGERTHA_GROQ_API_KEY};
  push @available, 'mistral'   if $ENV{TEST_LANGERTHA_MISTRAL_API_KEY};
  push @available, 'deepseek'    if $ENV{TEST_LANGERTHA_DEEPSEEK_API_KEY};
  push @available, 'minimax'     if $ENV{TEST_LANGERTHA_MINIMAX_API_KEY};
  # Perplexity does not support tool calling
  push @available, 'nousresearch' if $ENV{TEST_LANGERTHA_NOUSRESEARCH_API_KEY};
  push @available, 'aki'        if $ENV{TEST_LANGERTHA_AKI_API_KEY};
  push @available, 'ollama'      if $ENV{TEST_LANGERTHA_OLLAMA_URL};
  push @available, 'vllm'      if $ENV{TEST_LANGERTHA_VLLM_URL} && $ENV{TEST_LANGERTHA_VLLM_TOOL_CALL_PARSER};
  unless (@available) {
    plan skip_all => 'No TEST_LANGERTHA_* env vars set';
  }
  eval {
    require IO::Async::Loop;
    require Future::AsyncAwait;
    require Net::Async::MCP;
    require MCP::Server;
    require MCP::Tool;
    1;
  } or plan skip_all => 'Requires IO::Async, Net::Async::MCP, and MCP modules';
}

use IO::Async::Loop;
use Future::AsyncAwait;
use Net::Async::MCP;
use MCP::Server;
use MCP::Tool;

# --- Build a test MCP server with deterministic tools ---

my $server = MCP::Server->new(name => 'test', version => '1.0');

$server->tool(
  name        => 'add',
  description => 'Add two numbers together and return the result',
  input_schema => {
    type       => 'object',
    properties => {
      a => { type => 'number', description => 'First number' },
      b => { type => 'number', description => 'Second number' },
    },
    required => ['a', 'b'],
  },
  code => sub {
    my ($self, $args) = @_;
    my $result = $args->{a} + $args->{b};
    return $self->text_result("$result");
  },
);

my $loop = IO::Async::Loop->new;
my $mcp = Net::Async::MCP->new(server => $server);
$loop->add($mcp);

my $prompt = 'What is 7 plus 15? Use the add tool to calculate this. Answer with just the number.';

async sub test_engine {
  my ($name, $engine) = @_;
  my $response = await $engine->chat_with_tools_f($prompt);
  like($response, qr/22/, "$name: tool calling returned correct result (22)");
  diag "$name response: $response";
}

async sub run_tests {
  await $mcp->initialize;

  my $tools = await $mcp->list_tools;
  is(scalar @$tools, 1, 'MCP server has 1 tool');
  is($tools->[0]{name}, 'add', 'tool is add');

  # --- Anthropic ---
  if ($ENV{TEST_LANGERTHA_ANTHROPIC_API_KEY}) {
    require Langertha::Engine::Anthropic;
    eval {
      await test_engine('Anthropic', Langertha::Engine::Anthropic->new(
        api_key => $ENV{TEST_LANGERTHA_ANTHROPIC_API_KEY},
        model => 'claude-sonnet-4-6', mcp_servers => [$mcp],
      ));
    };
    diag "Anthropic error: $@" if $@;
  }

  # --- OpenAI ---
  if ($ENV{TEST_LANGERTHA_OPENAI_API_KEY}) {
    require Langertha::Engine::OpenAI;
    eval {
      await test_engine('OpenAI', Langertha::Engine::OpenAI->new(
        api_key => $ENV{TEST_LANGERTHA_OPENAI_API_KEY},
        model => 'gpt-4o-mini', mcp_servers => [$mcp],
      ));
    };
    diag "OpenAI error: $@" if $@;
  }

  # --- Gemini ---
  if ($ENV{TEST_LANGERTHA_GEMINI_API_KEY}) {
    require Langertha::Engine::Gemini;
    eval {
      await test_engine('Gemini', Langertha::Engine::Gemini->new(
        api_key => $ENV{TEST_LANGERTHA_GEMINI_API_KEY},
        model => 'gemini-2.5-flash', mcp_servers => [$mcp],
      ));
    };
    diag "Gemini error: $@" if $@;
  }

  # --- Groq ---
  if ($ENV{TEST_LANGERTHA_GROQ_API_KEY}) {
    require Langertha::Engine::Groq;
    eval {
      await test_engine('Groq', Langertha::Engine::Groq->new(
        api_key => $ENV{TEST_LANGERTHA_GROQ_API_KEY},
        model => 'llama-3.3-70b-versatile', mcp_servers => [$mcp],
      ));
    };
    diag "Groq error: $@" if $@;
  }

  # --- Mistral ---
  if ($ENV{TEST_LANGERTHA_MISTRAL_API_KEY}) {
    require Langertha::Engine::Mistral;
    eval {
      await test_engine('Mistral', Langertha::Engine::Mistral->new(
        api_key => $ENV{TEST_LANGERTHA_MISTRAL_API_KEY},
        model => 'mistral-small-latest', mcp_servers => [$mcp],
      ));
    };
    diag "Mistral error: $@" if $@;
  }

  # --- DeepSeek ---
  if ($ENV{TEST_LANGERTHA_DEEPSEEK_API_KEY}) {
    require Langertha::Engine::DeepSeek;
    eval {
      await test_engine('DeepSeek', Langertha::Engine::DeepSeek->new(
        api_key => $ENV{TEST_LANGERTHA_DEEPSEEK_API_KEY},
        model => 'deepseek-chat', mcp_servers => [$mcp],
      ));
    };
    diag "DeepSeek error: $@" if $@;
  }

  # --- MiniMax ---
  if ($ENV{TEST_LANGERTHA_MINIMAX_API_KEY}) {
    require Langertha::Engine::MiniMax;
    eval {
      await test_engine('MiniMax', Langertha::Engine::MiniMax->new(
        api_key => $ENV{TEST_LANGERTHA_MINIMAX_API_KEY},
        mcp_servers => [$mcp],
      ));
    };
    diag "MiniMax error: $@" if $@;
  }

  # --- Perplexity ---
  # Note: Perplexity does not support tool calling as of Feb 2026
  # Skipped in tool calling test

  # --- NousResearch ---
  if ($ENV{TEST_LANGERTHA_NOUSRESEARCH_API_KEY}) {
    require Langertha::Engine::NousResearch;
    eval {
      await test_engine('NousResearch', Langertha::Engine::NousResearch->new(
        api_key => $ENV{TEST_LANGERTHA_NOUSRESEARCH_API_KEY},
        model => 'Hermes-3-Llama-3.1-70B', mcp_servers => [$mcp],
      ));
    };
    diag "NousResearch error: $@" if $@;
  }

  # --- vLLM ---
  # Requires server started with: --enable-auto-tool-choice --tool-call-parser <parser>
  # Set TEST_LANGERTHA_VLLM_TOOL_CALL_PARSER to indicate tool calling is available
  if ($ENV{TEST_LANGERTHA_VLLM_URL} && $ENV{TEST_LANGERTHA_VLLM_TOOL_CALL_PARSER}) {
    require Langertha::Engine::vLLM;
    my $model = $ENV{TEST_LANGERTHA_VLLM_MODEL}
      or die "TEST_LANGERTHA_VLLM_MODEL required when TEST_LANGERTHA_VLLM_URL is set";
    diag "vLLM tool_call_parser: $ENV{TEST_LANGERTHA_VLLM_TOOL_CALL_PARSER}";
    eval {
      await test_engine("vLLM/$model", Langertha::Engine::vLLM->new(
        url => $ENV{TEST_LANGERTHA_VLLM_URL},
        model => $model, mcp_servers => [$mcp],
      ));
    };
    diag "vLLM/$model error: $@" if $@;
  }

  # --- AKI.IO (via OpenAI-compatible API) ---
  if ($ENV{TEST_LANGERTHA_AKI_API_KEY}) {
    require Langertha::Engine::AKIOpenAI;
    # Pick a chat model from available endpoints
    my $aki_model = $ENV{TEST_LANGERTHA_AKI_MODEL} || 'llama3_8b_chat';
    eval {
      await test_engine("AKI/$aki_model", Langertha::Engine::AKIOpenAI->new(
        api_key => $ENV{TEST_LANGERTHA_AKI_API_KEY},
        model => $aki_model, mcp_servers => [$mcp],
      ));
    };
    diag "AKI/$aki_model error: $@" if $@;
  }

  # --- Ollama ---
  if ($ENV{TEST_LANGERTHA_OLLAMA_URL}) {
    require Langertha::Engine::Ollama;
    my @ollama_models = $ENV{TEST_LANGERTHA_OLLAMA_MODELS}
      ? split(/,/, $ENV{TEST_LANGERTHA_OLLAMA_MODELS})
      : ($ENV{TEST_LANGERTHA_OLLAMA_MODEL} || 'qwen3:8b');
    for my $model (@ollama_models) {
      eval {
        await test_engine("Ollama/$model", Langertha::Engine::Ollama->new(
          url => $ENV{TEST_LANGERTHA_OLLAMA_URL},
          model => $model, mcp_servers => [$mcp],
        ));
      };
      diag "Ollama/$model error: $@" if $@;
    }
  }
}

run_tests()->get;

done_testing;
