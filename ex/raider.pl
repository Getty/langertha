#!/usr/bin/env perl
# ABSTRACT: Raider agent example — autonomous file explorer
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
use Langertha::Raider;

# --- Build an MCP server with file exploration tools ---

my $server = MCP::Server->new(name => 'files', version => '1.0');

$server->tool(
  name        => 'list_files',
  description => 'List files and directories at the given path',
  input_schema => {
    type       => 'object',
    properties => {
      path => { type => 'string', description => 'Directory path to list' },
    },
    required => ['path'],
  },
  code => sub {
    my ($self, $args) = @_;
    my $path = $args->{path};
    return $self->text_result("Error: not a directory: $path") unless -d $path;
    opendir(my $dh, $path) or return $self->text_result("Error: $!");
    my @entries = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);
    return $self->text_result(join("\n", @entries) || '(empty directory)');
  },
);

$server->tool(
  name        => 'read_file',
  description => 'Read the contents of a file (first 200 lines)',
  input_schema => {
    type       => 'object',
    properties => {
      path => { type => 'string', description => 'File path to read' },
    },
    required => ['path'],
  },
  code => sub {
    my ($self, $args) = @_;
    my $path = $args->{path};
    return $self->text_result("Error: not a file: $path") unless -f $path;
    open(my $fh, '<', $path) or return $self->text_result("Error: $!");
    my @lines;
    while (<$fh>) {
      push @lines, $_;
      last if @lines >= 200;
    }
    close($fh);
    return $self->text_result(join('', @lines));
  },
);

# --- Set up MCP client ---

my $loop = IO::Async::Loop->new;
my $mcp = Net::Async::MCP->new(server => $server);
$loop->add($mcp);

async sub main {
  await $mcp->initialize;

  my $tools = await $mcp->list_tools;
  printf "Tools: %s\n\n", join(', ', map { $_->{name} } @$tools);

  # --- Create the Raider ---

  my $engine = Langertha::Engine::Anthropic->new(
    api_key     => $ENV{ANTHROPIC_API_KEY} || die("Set ANTHROPIC_API_KEY"),
    model       => 'claude-sonnet-4-6',
    mcp_servers => [$mcp],
  );

  my $raider = Langertha::Raider->new(
    engine  => $engine,
    mission => 'You are a code explorer. Use the available tools to investigate '
             . 'the codebase. Be concise in your answers.',
  );

  # --- First raid: explore ---

  printf "=== Raid 1: Explore ===\n";
  my $r1 = await $raider->raid_f('What files are in the lib/ directory of this project?');
  printf "%s\n\n", $r1;

  printf "History: %d messages\n", scalar @{$raider->history};
  printf "Metrics: raids=%d, tool_calls=%d, time=%.0fms\n\n",
    $raider->metrics->{raids},
    $raider->metrics->{tool_calls},
    $raider->metrics->{time_ms};

  # --- Second raid: follow-up using history ---

  printf "=== Raid 2: Follow-up ===\n";
  my $r2 = await $raider->raid_f('Read the main module file and summarize what this project does.');
  printf "%s\n\n", $r2;

  printf "History: %d messages\n", scalar @{$raider->history};
  printf "Metrics: raids=%d, tool_calls=%d, time=%.0fms\n",
    $raider->metrics->{raids},
    $raider->metrics->{tool_calls},
    $raider->metrics->{time_ms};

  # --- Flush Langfuse events (if enabled) ---

  if ($engine->langfuse_enabled) {
    printf "\n%s\n", "=" x 60;
    printf "Flushing %d Langfuse events...\n", scalar @{$engine->_langfuse_batch};
    my $flush = $engine->langfuse_flush;
    printf "  HTTP %s\n", $flush->status_line;
    printf "  Dashboard: %s\n", $engine->langfuse_url;
  }
}

main()->get;
