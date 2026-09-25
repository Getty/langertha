#!/usr/bin/env perl
# ABSTRACT: chat_f puts every tools item on the wire in the engine's tool_wire_format
use strict;
use warnings;

use Test2::Bundle::More;
use lib 't/lib';

use JSON::MaybeXS;
use Langertha::Engine::OpenAI;
use Langertha::Engine::OpenAIResponses;
use Langertha::Engine::Anthropic;
use Langertha::Engine::Gemini;
use Langertha::Engine::Ollama;
use Langertha::Engine::NousResearch;
use Langertha::ServerTool;
use Langertha::Tool;
use Test::MockAsyncHTTP;

# karr k227 (ADR 0001): chat_f handed `tools` to chat_request raw, so a
# Langertha::Tool went out through TO_JSON in its canonical to_hash shape --
# which only the Anthropic wire reads; OpenAI, Gemini and Ollama got an invalid
# tool and answered 400. chat_f now shapes the list through the same one path
# as chat_stream_realtime_f (k221). What must NOT move: a hash that is already
# in the wire's own shape is the caller's wire intent and goes out byte for
# byte -- it carries the extras the value objects do not model
# (function.strict, cache_control) and the provider built-ins
# (web_search_20250305, google_search) the Tool door refuses.

my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );

my %reply = (
  openai    => { choices => [ { message => { role => 'assistant', content => 'ok' }, finish_reason => 'stop' } ] },
  anthropic => { id => 'msg_1', type => 'message', role => 'assistant',
    content => [ { type => 'text', text => 'ok' } ], stop_reason => 'end_turn' },
  gemini    => { candidates => [ { content => { role => 'model', parts => [ { text => 'ok' } ] }, finishReason => 'STOP' } ] },
  ollama    => { model => 'qwen3:8b', message => { role => 'assistant', content => 'ok' }, done => JSON->true },
  responses => { output => [ { type => 'message', role => 'assistant',
    content => [ { type => 'output_text', text => 'ok' } ] } ] },
);
$reply{hermes} = $reply{openai};

my %make = (
  openai    => sub { Langertha::Engine::OpenAI->new( api_key => 'k', model => 'gpt-4o-mini', @_ ) },
  anthropic => sub { Langertha::Engine::Anthropic->new( api_key => 'k', model => 'claude-sonnet-4-6', @_ ) },
  gemini    => sub { Langertha::Engine::Gemini->new( api_key => 'k', model => 'gemini-3-flash-preview', @_ ) },
  ollama    => sub { Langertha::Engine::Ollama->new( url => 'http://127.0.0.1:11434', model => 'qwen3:8b', @_ ) },
  responses => sub { Langertha::Engine::OpenAIResponses->new( api_key => 'k', model => 'gpt-5.6-luna', @_ ) },
  hermes    => sub { Langertha::Engine::NousResearch->new( api_key => 'k', model => 'Hermes-4-70B', @_ ) },
);

# ($engine, $mock) for one wire; the engine sends through the mock.
sub engine_for {
  my ($fmt) = @_;
  my $mock = Test::MockAsyncHTTP->new(
    responses => [ Test::MockAsyncHTTP->mock_json_response( $reply{$fmt} ) ] );
  my $engine = $make{$fmt}->( _async_http => $mock );
  is( $engine->tool_wire_format, $fmt, "engine speaks the $fmt tool wire" );
  return ( $engine, $mock );
}

# The raw request bytes chat_f sent for @tools.
sub chat_f_bytes {
  my ( $fmt, $tools ) = @_;
  my ( $engine, $mock ) = engine_for($fmt);
  my $response = $engine->chat_f( messages => ['hi'], tools => $tools )->get;
  ok( defined $response, "$fmt: chat_f answered" );
  my ($request) = $mock->requests;
  return $request->content;
}
sub chat_f_tools { $json->decode( chat_f_bytes(@_) )->{tools} }

# The bytes chat_request builds for the same tools when nothing reshapes them.
sub direct_bytes {
  my ( $fmt, $tools ) = @_;
  my ($engine) = engine_for($fmt);
  return $engine->chat_request( $engine->chat_messages('hi'), tools => $tools )->content;
}

my $schema = { type => 'object', properties => { a => { type => 'number' } }, required => ['a'] };

# Hashes that are already in each wire's own shape, extras and built-ins
# included, plus a typed item Langertha does not know (Moonshot's builtin
# function on an OpenAI-compatible wire): the provider judges those.
my %native = (
  openai => [
    { type => 'function', function => { name => 'add', description => 'Add', parameters => $schema, strict => JSON->true } },
    { type => 'builtin_function', function => { name => '$web_search' } },
  ],
  anthropic => [
    { type => 'web_search_20250305', name => 'web_search', max_uses => 1 },
    { name => 'add', description => 'Add', input_schema => $schema, cache_control => { type => 'ephemeral' } },
  ],
  gemini => [
    { google_search => {} },
    { functionDeclarations => [ { name => 'add', description => 'Add', parameters => $schema, behavior => 'BLOCKING' } ] },
  ],
  ollama => [
    { type => 'function', function => { name => 'add', description => 'Add', parameters => $schema } },
  ],
  responses => [
    { type => 'function', name => 'add', description => 'Add', parameters => $schema, strict => JSON->true },
    { type => 'web_search' },
  ],
  hermes => [
    { type => 'function', function => { name => 'add', description => 'Add', parameters => $schema } },
  ],
);

subtest 'pin: wire-shaped hashes go out byte for byte' => sub {
  for my $fmt (qw( openai anthropic gemini ollama responses hermes )) {
    is( chat_f_bytes( $fmt, $native{$fmt} ), direct_bytes( $fmt, $native{$fmt} ),
      "$fmt: the chat_f body equals the body chat_request builds from the same hashes" );
    is_deeply( chat_f_tools( $fmt, $native{$fmt} ), $native{$fmt}, "$fmt: every hash verbatim, in order" );
  }
};

done_testing;
