#!/usr/bin/env perl
# ABSTRACT: response_tool_calls and response_text_content read a Langertha::Response through its raw body and croak on other objects
use strict;
use warnings;
use Test2::V0;
use HTTP::Response;
use JSON::MaybeXS;
use Langertha::Engine::Anthropic;
use Langertha::Engine::OpenAI;

# Since 0.503 (k341) both readers went through ToolCall->locate, which answered
# [] / '' for anything but a plain HASH: handing them what response_call
# returns (a Langertha::Response) lost the tool calls and the text without an
# error. A Response is now read through its raw body; any other object croaks.

my $body = {
  id => 'm', type => 'message', role => 'assistant', model => 'c', stop_reason => 'tool_use',
  content => [
    { type => 'text', text => 'ok' },
    { type => 'tool_use', id => 't1', name => 'add', input => { a => 1 } },
  ],
  usage => { input_tokens => 1, output_tokens => 1 },
};

my $engine  = Langertha::Engine::Anthropic->new( api_key => 'x', langfuse_enabled => 0 );
my $request = $engine->build_tool_chat_request( [ { role => 'user', content => 'hi' } ] );
my $http    = HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'application/json' ], encode_json($body) );
my $reply   = $request->response_call->($http);

isa_ok( $reply, ['Langertha::Response'], 'response_call returns a Langertha::Response' );
is( scalar @{ $reply->tool_calls }, 1, 'the response itself carries the call' );

my $calls = $engine->response_tool_calls($reply);
is( scalar @$calls, 1, 'response_tool_calls on the Response finds the call' );
is( [ $engine->extract_tool_call( $calls->[0] ) ], [ 'add', { a => 1 } ], 'and it parses' );
is( $engine->response_text_content($reply), 'ok', 'response_text_content on the Response reads the text' );

is( $engine->response_tool_calls($body), $calls, 'a plain body gives the same calls' );
is( $engine->response_text_content($body), 'ok', 'and the same text' );

like( dies { $engine->response_tool_calls( bless {}, 'Some::Thing' ) },
  qr/response_tool_calls: expects the parsed response body.*got a Some::Thing/, 'another object croaks' );
like( dies { $engine->response_text_content( bless {}, 'Some::Thing' ) },
  qr/response_text_content: expects the parsed response body/, 'for the text reader too' );

my $rawless = Langertha::Response->new( content => 'x' );
like( dies { $engine->response_tool_calls($rawless) }, qr/carries no raw body/, 'a Response without raw croaks' );

is( $engine->response_tool_calls(undef), [], 'undef stays empty' );
is( Langertha::Engine::OpenAI->new( api_key => 'x', langfuse_enabled => 0 )->response_tool_calls({}), [], 'an empty body stays empty' );

done_testing;
