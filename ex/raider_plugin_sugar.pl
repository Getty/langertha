#!/usr/bin/env perl
# ABSTRACT: Plugin sugar demo — custom Raider + Plugin classes
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

$|=1;

use IO::Async::Loop;
use Future::AsyncAwait;

# --- Define a custom plugin using sugar ---

{
  package MyApp::Plugin::Guardrails;
  use Langertha qw( Plugin );

  has blocked_tools => (is => 'ro', default => sub { ['dangerous_tool'] });

  async sub plugin_before_tool_call {
    my ( $self, $name, $input ) = @_;
    for my $blocked (@{$self->blocked_tools}) {
      if ($name eq $blocked) {
        print "  [Guardrails] BLOCKED tool: $name\n";
        return ();  # skip
      }
    }
    print "  [Guardrails] Allowed tool: $name\n";
    return ($name, $input);
  }

  __PACKAGE__->meta->make_immutable;
}

# --- Define a custom Raider using sugar ---

{
  package MyApp::Agent;
  use Langertha qw( Raider );

  plugin 'MyApp::Plugin::Guardrails';

  has custom_greeting => (is => 'ro', default => 'Hello from MyApp::Agent!');

  __PACKAGE__->meta->make_immutable;
}

# --- Run ---

use Langertha::Engine::Anthropic;

async sub main {
  my $engine = Langertha::Engine::Anthropic->new(
    api_key => $ENV{ANTHROPIC_API_KEY} || die("Set ANTHROPIC_API_KEY\n"),
    model   => 'claude-sonnet-4-6',
  );

  my $agent = MyApp::Agent->new(
    engine       => $engine,
    raider_mcp   => 1,
    mission      => 'You are a helpful assistant.',
  );

  printf "%s\n", $agent->custom_greeting;
  printf "Plugins: %s\n\n", join(', ', @{$agent->plugins});

  my $result = await $agent->raid_f('What is 2+2? Be brief.');
  printf "Result: %s\n", $result;
}

main()->get;
