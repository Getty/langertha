#!/usr/bin/env perl
use strict;
use warnings;
use Test2::Bundle::More;

# Skip if IO::Async not available
BEGIN {
  eval { require IO::Async::Loop; require Net::Async::HTTP; 1 }
    or plan skip_all => 'IO::Async and Net::Async::HTTP not installed';
}

plan(5);

use Langertha::Engine::OpenAI;

my $openai = Langertha::Engine::OpenAI->new(
  api_key => 'test-key',
  model => 'gpt-4o-mini',
);

# Test that the Future methods are available directly
ok($openai->can('simple_chat_f'), 'simple_chat_f method available');
ok($openai->can('simple_chat_stream_f'), 'simple_chat_stream_f method available');
ok($openai->can('simple_chat_stream_realtime_f'), 'simple_chat_stream_realtime_f method available');

# Test async http creation
my $http = $openai->_async_http;
ok($http->isa('Net::Async::HTTP'), '_async_http returns Net::Async::HTTP');

# Test loop creation
my $loop = $openai->_async_loop;
ok($loop->isa('IO::Async::Loop'), '_async_loop returns IO::Async::Loop');

done_testing;
