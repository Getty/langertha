#!/usr/bin/env perl
# ABSTRACT: Tool loops answer an unknown tool with an error result and send a duplicate name once

use strict;
use warnings;

use Test2::Bundle::More;

# karr k332, two tool-loop faults:
#
#   A call to a name no MCP server offers (a hallucinated tool) died with
#   "Tool 'x' not found on any MCP server" after the earlier calls of the same
#   batch had already run -- their side effects happened, their results were
#   lost, and the model never learned the name was wrong. Every call of the
#   batch is now answered: an unknown one with an is_error "unknown tool x"
#   result, the rest run.
#
#   Two MCP servers offering the same tool name put two identical function
#   declarations on the wire, which providers reject. The name is sent once,
#   runs on the first server, and a carp names both servers.

use lib 't/lib';
use Test::MockMCP;
use Test::ToolLoop qw( run_loop loop_names );

use Langertha::Engine::OpenAI;
use Langertha::Engine::Anthropic;

my %engine = (
  openai    => sub { Langertha::Engine::OpenAI->new( api_key => 'k', model => 'gpt-x', @_ ) },
  anthropic => sub { Langertha::Engine::Anthropic->new( api_key => 'k', model => 'claude-x', response_size => 256, @_ ) },
);

sub server {
  my ( $calls, @names ) = @_;
  return Test::MockMCP->new( tools => [ map {
    my $name = $_;
    { name => $name, description => $name, input_schema => { type => 'object', properties => {} },
      code => sub { push @$calls, $name; $_[0]->text_result("ran $name") } }
  } @names ] );
}

my $openai_batch = { id => 'c1', choices => [ { index => 0, finish_reason => 'tool_calls',
  message => { role => 'assistant', content => undef, tool_calls => [
    map { { id => $_->[0], type => 'function', function => { name => $_->[1], arguments => '{}' } } }
      [ c1 => 'echo' ], [ c2 => 'web_search' ], [ c3 => 'echo' ],
  ] } } ] };
my $openai_done = { id => 'c2', choices => [ { index => 0, finish_reason => 'stop',
  message => { role => 'assistant', content => 'done' } } ] };

subtest 'openai: an unknown tool mid-batch is answered, the batch runs to the end' => sub {
  for my $loop ( loop_names() ) {
    my @calls;
    my $out = run_loop( $loop, engine => $engine{openai},
      bodies => [ $openai_batch, $openai_done ], servers => [ server( \@calls, 'echo' ) ] );
    is( $out->{ok}, 'done', "$loop does not die" ) or diag( $out->{died} // '' );
    is_deeply( \@calls, [ 'echo', 'echo' ], "$loop ran both known calls" );
    my @results = grep { ( $_->{role} // '' ) eq 'tool' } @{ $out->{requests}[1]{messages} };
    is_deeply( [ map { $_->{tool_call_id} } @results ], [qw( c1 c2 c3 )],
      "$loop answers every call of the batch" );
    like( $results[1]{content}, qr/unknown tool web_search/, "$loop tells the model the name is unknown" );
  }
};

subtest 'anthropic: the unknown-tool result is an error' => sub {
  my $batch = { id => 'msg_1', type => 'message', role => 'assistant', model => 'claude-x',
    stop_reason => 'tool_use', content => [
      { type => 'tool_use', id => 'toolu_1', name => 'web_search', input => {} },
      { type => 'tool_use', id => 'toolu_2', name => 'echo', input => {} } ] };
  my $done = { id => 'msg_2', type => 'message', role => 'assistant', model => 'claude-x',
    stop_reason => 'end_turn', content => [ { type => 'text', text => 'done' } ] };
  for my $loop ( loop_names() ) {
    my @calls;
    my $out = run_loop( $loop, engine => $engine{anthropic},
      bodies => [ $batch, $done ], servers => [ server( \@calls, 'echo' ) ] );
    is( $out->{ok}, 'done', "$loop does not die" ) or diag( $out->{died} // '' );
    is_deeply( \@calls, ['echo'], "$loop ran the known call after the unknown one" );
    my $blocks = $out->{requests}[1]{messages}[-1]{content};
    is( $blocks->[0]{tool_use_id}, 'toolu_1', "$loop: first block answers the unknown call" );
    ok( $blocks->[0]{is_error}, "$loop: flagged is_error" );
    is_deeply( $blocks->[0]{content}, [ { type => 'text', text => 'unknown tool web_search' } ],
      "$loop: says which name" );
    ok( !$blocks->[1]{is_error}, "$loop: the real result is no error" );
  }
};

subtest 'a name two servers offer goes on the wire once and runs on the first' => sub {
  my $batch = { id => 'c1', choices => [ { index => 0, finish_reason => 'tool_calls',
    message => { role => 'assistant', content => undef, tool_calls => [
      { id => 'c1', type => 'function', function => { name => 'search', arguments => '{}' } } ] } } ] };
  for my $loop ( loop_names() ) {
    my ( @first, @second );
    my $out = run_loop( $loop, engine => $engine{openai}, bodies => [ $batch, $openai_done ],
      servers => [ server( \@first, 'search', 'echo' ), server( \@second, 'search' ) ] );
    is( $out->{ok}, 'done', "$loop finishes" ) or diag( $out->{died} // '' );
    is_deeply( [ map { $_->{function}{name} } @{ $out->{requests}[0]{tools} } ], [qw( search echo )],
      "$loop declares search once" );
    is_deeply( [ \@first, \@second ], [ ['search'], [] ], "$loop runs it on the first server" );
    my @carps = grep { /tool 'search' is offered by MCP server 1 \(Test::MockMCP\) and MCP server 2 \(Test::MockMCP\); using the first/ }
      @{ $out->{warnings} };
    is( scalar @carps, 1, "$loop carps once, naming both servers" )
      or diag explain $out->{warnings};
  }
};

done_testing;
