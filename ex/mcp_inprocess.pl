#!/usr/bin/env perl
# ABSTRACT: MCP tool calling with an in-process Perl MCP server
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

$|=1;

use IO::Async::Loop;
use Future::AsyncAwait;
use Net::Async::MCP;
use MCP::Server;
use Langertha::Engine::Anthropic;

# --- Build a simple in-process MCP server with two tools ---

my $server = MCP::Server->new(name => 'demo', version => '1.0');

$server->tool(
  name        => 'add',
  description => 'Add two numbers',
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
  name        => 'greet',
  description => 'Generate a greeting message for a person',
  input_schema => {
    type       => 'object',
    properties => {
      name => { type => 'string', description => 'Name of the person' },
    },
    required => ['name'],
  },
  code => sub {
    my ($self, $args) = @_;
    return $self->text_result("Hello, $args->{name}! Welcome!");
  },
);

# --- Set up the MCP client (in-process transport) ---

my $loop = IO::Async::Loop->new;

my $mcp = Net::Async::MCP->new(server => $server);
$loop->add($mcp);

async sub main {
  await $mcp->initialize;

  my $tools = await $mcp->list_tools;
  printf "Available tools: %s\n", join(', ', map { $_->{name} } @$tools);

  # --- Create the Anthropic engine with MCP ---

  my $engine = Langertha::Engine::Anthropic->new(
    api_key     => $ENV{ANTHROPIC_API_KEY} || die("Set ANTHROPIC_API_KEY"),
    model       => 'claude-sonnet-4-6',
    mcp_servers => [$mcp],
  );

  # --- Run a tool-calling conversation ---

  printf "\nAsking Claude to use tools...\n\n";

  my $response = await $engine->chat_with_tools_f(
    'Please greet Alice and then calculate 42 + 17.'
  );

  printf "Final response:\n%s\n", $response;
}

main()->get;
