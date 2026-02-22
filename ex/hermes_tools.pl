#!/usr/bin/env perl
# ABSTRACT: Hermes-native tool calling with NousResearch
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

$|=1;

use IO::Async::Loop;
use Future::AsyncAwait;
use Net::Async::MCP;
use MCP::Server;
use Langertha::Engine::NousResearch;

# --- Build a simple in-process MCP server ---

my $server = MCP::Server->new(name => 'demo', version => '1.0');

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

$server->tool(
  name        => 'multiply',
  description => 'Multiply two numbers together and return the result',
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
    my $result = $args->{a} * $args->{b};
    return $self->text_result("$result");
  },
);

# --- Set up the MCP client ---

my $loop = IO::Async::Loop->new;

my $mcp = Net::Async::MCP->new(server => $server);
$loop->add($mcp);

async sub main {
  await $mcp->initialize;

  my $tools = await $mcp->list_tools;
  printf "Available tools: %s\n", join(', ', map { $_->{name} } @$tools);

  # --- NousResearch with Hermes-native tool calling ---
  # hermes_tools is enabled by default for NousResearch.
  # Tools are injected into the system prompt as <tools> XML and
  # <tool_call> tags are parsed from the model's text output.

  my $engine = Langertha::Engine::NousResearch->new(
    api_key     => $ENV{NOUSRESEARCH_API_KEY} || die("Set NOUSRESEARCH_API_KEY"),
    model       => 'Hermes-3-Llama-3.1-70B',
    mcp_servers => [$mcp],
  );

  printf "\nAsking Hermes to use tools...\n\n";

  my $response = await $engine->chat_with_tools_f(
    'What is 7 plus 15? Then multiply the result by 3. Use the tools.'
  );

  printf "Final response:\n%s\n", $response;

  # --- You can also use hermes_tools with any OpenAI-compatible engine ---
  # Useful for APIs that don't support the native tools parameter:
  #
  #   use Langertha::Engine::OpenAI;
  #   my $engine = Langertha::Engine::OpenAI->new(
  #     url          => 'https://some-openai-compatible-api.com/v1',
  #     api_key      => $ENV{API_KEY},
  #     model        => 'some-hermes-model',
  #     hermes_tools => 1,
  #     mcp_servers  => [$mcp],
  #   );
  #
  # Or with Ollama for models without API-level tool support:
  #
  #   use Langertha::Engine::Ollama;
  #   my $ollama = Langertha::Engine::Ollama->new(
  #     url          => 'http://localhost:11434',
  #     model        => 'hermes3',
  #     hermes_tools => 1,
  #     mcp_servers  => [$mcp],
  #   );
}

main()->get;
