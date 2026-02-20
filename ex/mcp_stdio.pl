#!/usr/bin/env perl
# ABSTRACT: MCP tool calling with a stdio MCP server subprocess
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

$|=1;

use IO::Async::Loop;
use Future::AsyncAwait;
use Net::Async::MCP;
use Langertha::Engine::Anthropic;

# --- Connect to a stdio MCP server ---
# This starts the server as a subprocess and communicates via JSON-RPC
# over stdin/stdout. Replace the command with any MCP-compatible server.

my $command = \@ARGV;
unless (@$command) {
  die <<"USAGE";
Usage: perl ex/mcp_stdio.pl <command> [args...]

Examples:
  perl ex/mcp_stdio.pl npx \@anthropic/mcp-server-web-search
  perl ex/mcp_stdio.pl python -m mcp_server_filesystem /tmp
  perl ex/mcp_stdio.pl perl my_mcp_server.pl
USAGE
}

my $loop = IO::Async::Loop->new;

my $mcp = Net::Async::MCP->new(command => $command);
$loop->add($mcp);

async sub main {
  printf "Starting MCP server: %s\n", join(' ', @$command);
  await $mcp->initialize;
  printf "Server initialized.\n\n";

  my $tools = await $mcp->list_tools;
  printf "Available tools (%d):\n", scalar @$tools;
  for my $tool (@$tools) {
    printf "  - %s: %s\n", $tool->{name}, $tool->{description} // '(no description)';
  }

  # --- Create the Anthropic engine with MCP ---

  my $engine = Langertha::Engine::Anthropic->new(
    api_key     => $ENV{ANTHROPIC_API_KEY} || die("Set ANTHROPIC_API_KEY"),
    model       => 'claude-sonnet-4-5-20250929',
    mcp_servers => [$mcp],
  );

  # --- Interactive loop ---

  printf "\nReady! Type a message (Ctrl-D to quit):\n\n";

  while (1) {
    print "> ";
    my $input = <STDIN>;
    last unless defined $input;
    chomp $input;
    next unless length $input;

    printf "\n";
    my $response = await $engine->chat_with_tools_f($input);
    printf "%s\n\n", $response;
  }

  printf "\nShutting down MCP server...\n";
  await $mcp->shutdown;
}

main()->get;
