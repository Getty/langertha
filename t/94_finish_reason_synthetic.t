#!/usr/bin/env perl
# ABSTRACT: finish_reason stays the provider's for a synthetic structured-output ToolCall, and traces report it (no network)

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;
use HTTP::Response;

use lib 't/lib';
use Test::MockAsyncHTTP;

use Langertha::Engine::Perplexity;
use Langertha::Engine::NousResearch;
use Langertha::Engine::Ollama;
use Langertha::Engine::Gemini;
use Langertha::Engine::Virtual;
use Langertha::Plugin::OTel;
use Langertha::Trace::OTLP;
use Langertha::Virtual::Rules qw( answer );

# When chat_f turns a forced named tool into a json_schema response_format,
# the model answers with plain text and stops on its own; the ToolCall on
# Response.tool_calls is Langertha's (synthetic => 1). The reply's
# finish_reason must stay what the provider sent, so a trace does not report
# a tool call the model never made. Calls the model really made (native, or
# lifted from hermes <tool_call> text) do read tool_calls over a wire 'stop';
# that rewrite is pinned elsewhere and must not reach the synthetic path.

my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );
my $tool = { name => 'extract', description => 'Extract',
  input_schema => { type => 'object', properties => { city => { type => 'string' } }, required => ['city'] } };
my $args_json = '{"city":"Berlin"}';

my %engine = (
  perplexity => {
    make  => sub { Langertha::Engine::Perplexity->new( api_key => 'k', model => 'sonar', @_ ) },
    reply => { id => 'resp_1', model => 'sonar', status => 'completed',
      output => [ { type => 'message', status => 'completed',
        content => [ { type => 'output_text', text => $args_json } ] } ],
      usage => { input_tokens => 1, output_tokens => 1, total_tokens => 2 } },
  },
  # A hermes engine: the chat_f reply lift runs too, and must leave the
  # synthetic path alone.
  nousresearch => {
    make  => sub { Langertha::Engine::NousResearch->new( api_key => 'k', model => 'Hermes-4-70B', @_ ) },
    reply => { choices => [ { message => { role => 'assistant', content => $args_json }, finish_reason => 'stop' } ] },
  },
  ollama => {
    make  => sub { Langertha::Engine::Ollama->new( url => 'http://127.0.0.1:11434', model => 'qwen3:8b', @_ ) },
    reply => { model => 'qwen3:8b', message => { role => 'assistant', content => $args_json },
      done => JSON->true, done_reason => 'stop' },
  },
);

for my $name ( sort keys %engine ) {
  subtest "$name: forced tool rewritten to json_schema keeps the provider's finish_reason" => sub {
    my $mock = Test::MockAsyncHTTP->new(
      responses => [ Test::MockAsyncHTTP->mock_json_response( $engine{$name}{reply} ) ] );
    my $e = $engine{$name}{make}->( _async_http => $mock );
    my $response = $e->chat_f( messages => ['Which city?'], tools => [$tool],
      tool_choice => { type => 'tool', name => 'extract' } )->get;

    my $tc = $response->tool_call('extract');
    ok( $tc && $tc->synthetic, 'the ToolCall is synthetic' );
    is_deeply( $response->finish_reason, 'stop', "finish_reason is the provider's stop, not tool_calls" );

    my %attr = Langertha::Trace::OTLP->response_attributes($response);
    is_deeply( $attr{'gen_ai.response.finish_reasons'}, ['stop'],
      'gen_ai.response.finish_reasons reports the provider value' );
  };
}

subtest 'contrast: a call the model made reads tool_calls over a wire stop' => sub {
  # NousResearch, no forced tool: the model writes a <tool_call> block and the
  # wire says stop. That is a real call, so finish_reason reads tool_calls;
  # ->raw keeps the wire value.
  my $reply = { choices => [ { message => { role => 'assistant',
    content => '<tool_call>{"name":"extract","arguments":{"city":"Berlin"}}</tool_call>' },
    finish_reason => 'stop' } ] };
  my $mock = Test::MockAsyncHTTP->new( responses => [ Test::MockAsyncHTTP->mock_json_response($reply) ] );
  my $e = Langertha::Engine::NousResearch->new( api_key => 'k', model => 'Hermes-4-70B', _async_http => $mock );
  my $response = $e->chat_f( messages => ['Which city?'], tools => [$tool] )->get;
  my $tc = $response->tool_call('extract');
  ok( $tc && !$tc->synthetic, 'a native (lifted) call, not synthetic' );
  is_deeply( $response->finish_reason, 'tool_calls', 'finish_reason tool_calls' );
  is_deeply( $response->raw->{choices}[0]{finish_reason}, 'stop', 'raw keeps the wire stop' );
};

subtest 'Gemini blocked prompt: raw blockReason on the span, content_filter in the output message' => sub {
  my $gemini = Langertha::Engine::Gemini->new( api_key => 'k', model => 'gemini-2.5-flash' );
  my $otel = Langertha::Plugin::OTel->new(
    host => Langertha::Engine::Virtual->new( langfuse_enabled => 0, fallback => answer('x') ),
    endpoint => 'http://127.0.0.1:9/v1/traces', headers => {}, capture_content => 1 );
  for my $reason (qw( SAFETY IMAGE_SAFETY )) {
    my $http = HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'application/json' ],
      $json->encode( { promptFeedback => { blockReason => $reason } } ) );
    my $response = $gemini->chat_response($http);
    is_deeply( $response->finish_reason, $reason, "$reason: finish_reason is the blockReason" );
    my %attr = Langertha::Trace::OTLP->response_attributes($response);
    is_deeply( $attr{'gen_ai.response.finish_reasons'}, [$reason], "$reason: span attribute unmapped" );
    my $output = $otel->_output_messages( undef, $response );
    is_deeply( $output->[0]{finish_reason}, 'content_filter', "$reason: output message finish_reason content_filter" );
  }
};

done_testing;
