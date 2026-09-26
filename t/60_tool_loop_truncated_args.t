#!/usr/bin/env perl
# ABSTRACT: The tool loops never run a call whose arguments were cut off by the token limit

use strict;
use warnings;

use Test2::Bundle::More;

# karr k324: a reply cut off by its token limit (finish_reason length,
# Anthropic stop_reason max_tokens, Gemini MAX_TOKENS) can carry a tool call
# whose arguments JSON string was cut too. ToolCall decoded it to {} and the
# loops ran the -- possibly side-effecting -- tool on empty input. The stream
# parser already drops an unfinished call; the loops now do the same: a lone
# truncated call croaks and tells the caller to raise response_size, a
# truncated call beside complete ones is dropped with a carp, and the
# assistant echo leaves it out so the next turn pairs every call with a result.

use lib 't/lib';
use Test::MockMCP;
use Test::ToolLoop qw( run_loop loop_names );

use Langertha::ToolCall;
use Langertha::Engine::OpenAI;
use Langertha::Engine::Anthropic;
use Langertha::Engine::Gemini;
use Langertha::Engine::OpenAIResponses;
use Langertha::Engine::Perplexity;

my %engine = (
  openai    => sub { Langertha::Engine::OpenAI->new( api_key => 'k', model => 'gpt-x', @_ ) },
  anthropic => sub { Langertha::Engine::Anthropic->new( api_key => 'k', model => 'claude-x', response_size => 256, @_ ) },
  gemini    => sub { Langertha::Engine::Gemini->new( api_key => 'k', model => 'gemini-x', @_ ) },
  responses => sub { Langertha::Engine::OpenAIResponses->new( api_key => 'k', model => 'gpt-x', @_ ) },
  perplexity => sub { Langertha::Engine::Perplexity->new( api_key => 'k', @_ ) },
);

sub echo_server {
  my ( $calls ) = @_;
  return Test::MockMCP->new( tools => [ { name => 'echo', description => 'Echo',
    input_schema => { type => 'object', properties => { m => { type => 'string' } } },
    code => sub { push @$calls, $_[1]; $_[0]->text_result('ok') } } ] );
}

sub openai_turn {
  my ( $finish, @calls ) = @_;
  return { id => 'c1', choices => [ { index => 0, finish_reason => $finish,
    message => { role => 'assistant', content => undef, tool_calls => [
      map { { id => $_->[0], type => 'function', function => { name => 'echo', arguments => $_->[1] } } } @calls,
    ] } } ] };
}

my $openai_done = { id => 'c2', choices => [ { index => 0, finish_reason => 'stop',
  message => { role => 'assistant', content => 'done' } } ] };

subtest 'ToolCall records arguments that do not decode' => sub {
  my $cut = Langertha::ToolCall->from_openai(
    { id => 'a', function => { name => 'echo', arguments => '{"m":"hello wor' } } );
  ok( $cut->arguments_undecodable, 'a cut-off JSON string' );
  is_deeply( $cut->arguments, {}, 'arguments are {}' );
  for my $case ( [ 'complete string', '{"m":"x"}' ], [ 'empty string', '' ], [ 'no arguments', undef ] ) {
    my $call = Langertha::ToolCall->from_openai(
      { id => 'a', function => { name => 'echo', arguments => $case->[1] } } );
    ok( !$call->arguments_undecodable, "$case->[0] is not undecodable" );
  }
  ok( Langertha::ToolCall->from_anthropic(
    { type => 'tool_use', id => 't', name => 'echo', input => '{"m":' } )->arguments_undecodable,
    'Anthropic string input (the /anthropic shims)' );
  ok( Langertha::ToolCall->from_gemini(
    { functionCall => { name => 'echo', args => '{"m":' } } )->arguments_undecodable,
    'Gemini string args (proxies)' );
  ok( Langertha::ToolCall->from_responses(
    { type => 'function_call', call_id => 'r', name => 'echo', arguments => '{"m":' } )->arguments_undecodable,
    'Responses arguments' );
};

my @lone = (
  [ openai => 'length', openai_turn( length => [ call_1 => '{"m":"hello wor' ] ) ],
  [ anthropic => 'max_tokens',
    { id => 'msg_1', type => 'message', role => 'assistant', model => 'claude-x',
      stop_reason => 'max_tokens', content => [
        { type => 'tool_use', id => 'toolu_1', name => 'echo', input => '{"m":"hel' } ] } ],
  [ gemini => 'MAX_TOKENS',
    { responseId => 'r1', modelVersion => 'gemini-x', candidates => [ { finishReason => 'MAX_TOKENS',
      content => { role => 'model', parts => [ { functionCall => { name => 'echo', args => '{"m":"hel' } } ] } } ] } ],
);

for my $case (@lone) {
  my ( $dialect, $reason, $body ) = @$case;
  subtest "$dialect: the only call was cut off ($reason)" => sub {
    for my $loop ( loop_names() ) {
      my @calls;
      my $out = run_loop( $loop, engine => $engine{$dialect},
        bodies => [ $body ], servers => [ echo_server( \@calls ) ] );
      like( $out->{died},
        qr/\ALangertha::Engine::\w+ tool call arguments truncated \(finish_reason \Q$reason\E\); raise response_size\z/,
        "$loop croaks" );
      is( scalar @calls, 0, "$loop ran no tool on {}" );
    }
  };
}

# karr k349: the Responses envelope (OpenAIResponses, Perplexity) decoded
# function_call arguments itself and died on a cut-off string with a raw JSON
# error, and a max_output_tokens reply holding only function calls reported
# finish_reason tool_calls, so the k324 drop never applied. The cut is
# reported on the envelope: status incomplete, incomplete_details.reason
# max_output_tokens (OpenAI Responses API reference).
my $responses_cut = { id => 'resp_1', object => 'response', status => 'incomplete', model => 'gpt-x',
  incomplete_details => { reason => 'max_output_tokens' },
  output => [ { type => 'function_call', id => 'fc_1', call_id => 'call_1', name => 'echo',
    arguments => '{"m":"hel', status => 'incomplete' } ] };

subtest 'responses: a max_output_tokens cut reads as length with the flag set' => sub {
  for my $dialect (qw( responses perplexity )) {
    my $r = eval { $engine{$dialect}->()->chat_response( Test::ToolLoop::http_for($responses_cut) ) };
    ok( defined $r, "$dialect: chat_response does not die" ) or diag($@);
    next unless $r;
    is( $r->finish_reason, 'length', "$dialect: finish_reason length" );
    ok( $r->tool_calls->[0]->arguments_undecodable, "$dialect: the call is flagged" );
  }
  my %complete = ( %$responses_cut, status => 'completed', incomplete_details => undef );
  is( $engine{responses}->()->chat_response( Test::ToolLoop::http_for( \%complete ) )->finish_reason,
    'tool_calls', 'a completed reply of function calls stays tool_calls' );
  my %filtered = ( %$responses_cut, incomplete_details => { reason => 'content_filter' } );
  is( $engine{responses}->()->chat_response( Test::ToolLoop::http_for( \%filtered ) )->finish_reason,
    'tool_calls', 'another incomplete reason is not a token limit' );
  my $chunk = $engine{perplexity}->()->parse_stream_chunk(
    { type => 'response.incomplete', response => $responses_cut }, 'response.incomplete' );
  is( $chunk->finish_reason, 'length', 'the terminal stream event reads the same' );
};

for my $dialect (qw( responses perplexity )) {
  subtest "$dialect: the only call was cut off (max_output_tokens)" => sub {
    for my $loop ( loop_names() ) {
      my @calls;
      my $out = run_loop( $loop, engine => $engine{$dialect},
        bodies => [ $responses_cut ], servers => [ echo_server( \@calls ) ] );
      like( $out->{died},
        qr/\ALangertha::Engine::\w+ tool call arguments truncated \(finish_reason length\); raise response_size\z/,
        "$loop croaks" );
      is( scalar @calls, 0, "$loop ran no tool on {}" );
    }
  };
}

subtest 'openai: a complete call beside a cut-off one runs alone' => sub {
  my $turn = openai_turn( length => [ call_1 => '{"m":"first"}' ], [ call_2 => '{"m":"sec' ] );
  for my $loop ( loop_names() ) {
    my @calls;
    my $out = run_loop( $loop, engine => $engine{openai},
      bodies => [ $turn, $openai_done ], servers => [ echo_server( \@calls ) ] );
    is( $out->{ok}, 'done', "$loop finishes" ) or diag( $out->{died} // '' );
    is_deeply( \@calls, [ { m => 'first' } ], "$loop ran only the complete call" );
    my @carps = grep { /dropped 1 tool call\(s\) with truncated arguments \(finish_reason length\): echo; raise response_size/ }
      @{ $out->{warnings} };
    is( scalar @carps, 1, "$loop carps once about the dropped call" );
    my $messages = $out->{requests}[1]{messages};
    my ($echo) = grep { ( $_->{role} // '' ) eq 'assistant' } @$messages;
    is_deeply( [ map { $_->{id} } @{ $echo->{tool_calls} } ], ['call_1'],
      "$loop: the echo carries only the call that ran" );
    is_deeply( [ map { $_->{tool_call_id} } grep { ( $_->{role} // '' ) eq 'tool' } @$messages ],
      ['call_1'], "$loop: one result, paired with it" );
  }
};

subtest 'openai: a length finish with complete arguments still runs' => sub {
  for my $loop ( loop_names() ) {
    my @calls;
    my $out = run_loop( $loop, engine => $engine{openai},
      bodies => [ openai_turn( length => [ call_1 => '{"m":"whole"}' ] ), $openai_done ],
      servers => [ echo_server( \@calls ) ] );
    is( $out->{ok}, 'done', "$loop finishes" ) or diag( $out->{died} // '' );
    is_deeply( \@calls, [ { m => 'whole' } ], "$loop ran the call" );
    is_deeply( $out->{warnings}, [], "$loop does not warn" );
  }
};

done_testing;
