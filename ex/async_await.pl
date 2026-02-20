#!/usr/bin/env perl
# ABSTRACT: Example of using Langertha with Future::AsyncAwait
use strict;
use warnings;
use v5.20;
use lib '../lib';

use Future::AsyncAwait;
use Langertha::Engine::Anthropic;

# Example 1: Simple async chat
async sub simple_example {
  my ($api_key) = @_;

  say "=== Example 1: Simple Async Chat ===\n";

  my $engine = Langertha::Engine::Anthropic->new(
    api_key => $api_key,
    model => 'claude-sonnet-4-5-20250929',
  );

  say "Asking Claude a question...";
  my $response = await $engine->simple_chat_f(
    'What is the capital of France? Answer in one word.'
  );

  say "Response: $response\n";
  return $response;
}

# Example 2: Streaming with real-time callback
async sub streaming_example {
  my ($api_key) = @_;

  say "=== Example 2: Streaming Chat with Real-time Callback ===\n";

  my $engine = Langertha::Engine::Anthropic->new(
    api_key => $api_key,
    model => 'claude-sonnet-4-5-20250929',
  );

  say "Streaming response (watch it appear in real-time):\n";
  print "AI: ";

  my ($content, $chunks) = await $engine->simple_chat_stream_realtime_f(
    sub {
      my ($chunk) = @_;
      print $chunk->content;  # Print each chunk as it arrives
      STDOUT->flush;
    },
    'Tell me a very short joke (one sentence).'
  );

  say "\n\nComplete! Received ", scalar(@$chunks), " chunks";
  say "Total content: $content\n";

  return $content;
}

# Example 3: Multiple concurrent requests
async sub concurrent_example {
  my ($api_key) = @_;

  say "=== Example 3: Concurrent Requests ===\n";

  my $engine = Langertha::Engine::Anthropic->new(
    api_key => $api_key,
    model => 'claude-haiku-4-5-20251001',  # Use faster model
  );

  say "Asking three questions concurrently...\n";

  # Start all three requests at once
  my $future1 = $engine->simple_chat_f('Capital of Germany? One word.');
  my $future2 = $engine->simple_chat_f('Capital of Italy? One word.');
  my $future3 = $engine->simple_chat_f('Capital of Spain? One word.');

  # Wait for all to complete
  my $result1 = await $future1;
  my $result2 = await $future2;
  my $result3 = await $future3;

  say "Germany: $result1";
  say "Italy: $result2";
  say "Spain: $result3\n";

  return [$result1, $result2, $result3];
}

# Example 4: Error handling with try/catch
async sub error_handling_example {
  my ($api_key) = @_;

  say "=== Example 4: Error Handling ===\n";

  my $engine = Langertha::Engine::Anthropic->new(
    api_key => 'invalid-key-for-testing',  # Intentionally invalid
    model => 'claude-sonnet-4-5-20250929',
  );

  say "Attempting request with invalid API key...\n";

  eval {
    my $response = await $engine->simple_chat_f('Hello');
    say "Response: $response";
  };

  if ($@) {
    say "✓ Caught expected error: $@";
  } else {
    say "✗ Should have failed with invalid API key!";
  }

  say "";
}

# Main execution
sub main {
  my $api_key = $ENV{ANTHROPIC_API_KEY};

  unless ($api_key) {
    say "This example requires ANTHROPIC_API_KEY environment variable.";
    say "\nUsage:";
    say "  export ANTHROPIC_API_KEY=your-key-here";
    say "  perl ex/async_await.pl";
    exit 1;
  }

  say "Langertha Future::AsyncAwait Examples\n";
  say "=" x 50 . "\n";

  # Run examples (they return Futures, so we need to ->get them)
  simple_example($api_key)->get;
  streaming_example($api_key)->get;
  concurrent_example($api_key)->get;

  # Error handling example doesn't need real API key
  error_handling_example($api_key)->get;

  say "=" x 50;
  say "\n✅ All examples completed!\n";
}

main() unless caller;

__END__

=head1 NAME

async_await.pl - Demonstrate Langertha with Future::AsyncAwait

=head1 DESCRIPTION

This script demonstrates the various ways to use Langertha's async/await
functionality powered by Future::AsyncAwait.

=head1 FEATURES DEMONSTRATED

=over 4

=item * Simple async chat requests

=item * Streaming with real-time callbacks

=item * Concurrent requests

=item * Error handling in async context

=back

=head1 REQUIREMENTS

Requires ANTHROPIC_API_KEY environment variable to be set.

=head1 USAGE

  export ANTHROPIC_API_KEY=your-key-here
  perl ex/async_await.pl

=cut
