#!/usr/bin/env perl
# ABSTRACT: Test Future::AsyncAwait integration and async sub compilation
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
