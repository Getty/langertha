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

my %engine = (
  openai    => sub { Langertha::Engine::OpenAI->new( api_key => 'k', model => 'gpt-x', @_ ) },
  anthropic => sub { Langertha::Engine::Anthropic->new( api_key => 'k', model => 'claude-x', response_size => 256, @_ ) },
  gemini    => sub { Langertha::Engine::Gemini->new( api_key => 'k', model => 'gemini-x', @_ ) },
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
