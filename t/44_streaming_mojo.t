#!/usr/bin/env perl
use strict;
use warnings;
use Test2::Bundle::More;

# Skip if Mojo::UserAgent not available
BEGIN {
  eval { require Mojo::UserAgent; 1 }
    or plan skip_all => 'Mojo::UserAgent not installed';
}

plan(6);

# Create test engine with Mojo support
package TestOpenAI {
  use Moose;
  extends 'Langertha::Engine::OpenAI';
  with 'Langertha::Role::Async::Mojo';
}

package main;

my $openai = TestOpenAI->new(
  api_key => 'test-key',
  model => 'gpt-4o-mini',
);

# Test that the role is applied
ok($openai->does('Langertha::Role::Async::Mojo'), 'Mojo role applied');
ok($openai->can('simple_chat_stream_p'), 'simple_chat_stream_p method available');
ok($openai->can('simple_chat_stream_realtime_p'), 'simple_chat_stream_realtime_p method available');
ok($openai->can('mojo_ua'), 'mojo_ua accessor available');

# Test mojo_ua creation
my $ua = $openai->mojo_ua;
ok($ua->isa('Mojo::UserAgent'), 'mojo_ua returns Mojo::UserAgent');

# Test request conversion
my $request = $openai->chat_stream('test');
my $tx = $openai->_request_to_mojo_tx($request);
ok($tx->isa('Mojo::Transaction::HTTP'), 'request converts to Mojo::Transaction');

done_testing;
