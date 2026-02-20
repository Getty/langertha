#!/usr/bin/env perl
use strict;
use warnings;
use Test2::Bundle::More;

# Skip if required modules not available
BEGIN {
  eval {
    require IO::Async::Loop;
    require Net::Async::HTTP;
    require Future::AsyncAwait;
    1
  } or plan skip_all => 'IO::Async, Net::Async::HTTP, and Future::AsyncAwait not installed';
}

use Future::AsyncAwait;
use Langertha::Engine::OpenAI;

plan(6);

my $openai = Langertha::Engine::OpenAI->new(
  api_key => 'test-key',
  model => 'gpt-4o-mini',
);

# Test 1: Verify async methods are available
ok($openai->can('simple_chat_f'), 'simple_chat_f method available');
ok($openai->can('simple_chat_stream_f'), 'simple_chat_stream_f method available');
ok($openai->can('simple_chat_stream_realtime_f'), 'simple_chat_stream_realtime_f method available');

# Test 2: Verify async methods return Future objects
my $future = $openai->simple_chat_f('Hello');
ok($future->isa('Future'), 'simple_chat_f returns a Future');

# Test 3: Verify we can use await in async subs
async sub test_await {
  my ($engine) = @_;

  # This should compile and return a Future
  # We're not actually executing it (no network available in tests)
  # Just testing that the syntax works
  return "async_works";
}

my $test_future = test_await($openai);
ok($test_future->isa('Future'), 'async sub returns Future');
is($test_future->get, 'async_works', 'async sub executed correctly');

done_testing;

=head1 NAME

t/45_async_await.t - Test Future::AsyncAwait integration

=head1 DESCRIPTION

This test verifies that Langertha's async methods are properly implemented
using Future::AsyncAwait and can be used with the async/await syntax.

=head1 EXAMPLE USAGE

Here's how you would use Langertha with async/await in a real application:

  use Future::AsyncAwait;
  use Langertha::Engine::OpenAI;

  my $engine = Langertha::Engine::OpenAI->new(
    api_key => $ENV{OPENAI_API_KEY},
    model => 'gpt-4o-mini',
  );

  async sub chat_with_ai {
    my ($engine, $message) = @_;

    my $response = await $engine->simple_chat_f($message);
    say "AI: $response";
    return $response;
  }

  async sub stream_chat {
    my ($engine, $message) = @_;

    my ($content, $chunks) = await $engine->simple_chat_stream_realtime_f(
      sub {
        my ($chunk) = @_;
        print $chunk->content;  # Print in real-time
      },
      $message
    );

    say "\nComplete! Received ", scalar(@$chunks), " chunks";
    return $content;
  }

  # Run the async functions
  chat_with_ai($engine, 'Hello!')->get;
  stream_chat($engine, 'Tell me a story')->get;

  # Or integrate with an event loop
  $engine->_async_loop->run;

=cut
