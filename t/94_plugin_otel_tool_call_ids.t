#!/usr/bin/env perl
# ABSTRACT: Langertha::Plugin::OTel pairs a tool span's start and end by the hooks' call HashRef, not by name: skips, renames and same-name calls (no network)

use strict;
use warnings;

use Test2::Bundle::More;
use Path::Tiny;
use IO::Socket::INET;
use JSON::MaybeXS;

use lib path(__FILE__)->parent->child('lib')->stringify;

use Test::MockMCP;

use Langertha::Chat;
use Langertha::Engine::Virtual;
use Langertha::Plugin::OTel;
use Langertha::Response;
use Langertha::ToolCall;
use Langertha::Virtual::Rules qw( answer tools );

my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );

# A clock that only moves when OTel reads it: every start and end is a
# distinct, ordered instant.
my $clock = 1000;
{
  no warnings 'redefine';
  *Langertha::Plugin::OTel::_now = sub { ++$clock };
}

my $mcp = Test::MockMCP->new( tools => [
  { name => 'lookup', description => 'Look something up',
    input_schema => { type => 'object', properties => { query => { type => 'string' } } },
    code => sub { my ( $self ) = @_; return $self->text_result('found') } },
] );

# A plugin placed after OTel: it skips the first call it sees, or renames
# 'alias' onto 'lookup', and notes the clock when it acts.
{
  package TestPlugin::Later;
  use Moose;
  use Future::AsyncAwait;
  extends 'Langertha::Plugin';
  has mode   => ( is => 'ro', default => 'skip' );
  has seen   => ( is => 'rw', default => 0 );
  has acted  => ( is => 'ro', default => sub { [] } );
  async sub plugin_before_tool_call {
    my ( $self, $name, $input ) = @_;
    $self->seen( $self->seen + 1 );
    if ( $self->mode eq 'skip' && $self->seen == 1 ) {
      push @{ $self->acted }, $clock;
      return;
    }
    if ( $self->mode eq 'rename' && $name eq 'alias' ) {
      push @{ $self->acted }, $clock;
      return ( 'lookup', $input );
    }
    return ( $name, $input );
  }
  __PACKAGE__->meta->make_immutable;
}

sub free_port {
  my $socket = IO::Socket::INET->new( Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0 ) or die $!;
  my $port = $socket->sockport;
  close $socket;
  return $port;
}

sub chat_for {
  my ( $calls, $mode ) = @_;
  my $engine = Langertha::Engine::Virtual->new(
    langfuse_enabled => 0,
    rules            => [ qr/\Ago\z/ => sub { tools($calls) } ],
    fallback         => answer('done'),
  );
  my $chat = Langertha::Chat->new(
    engine      => $engine,
    mcp_servers => [$mcp],
    plugins     => [
      OTel => { endpoint => 'http://127.0.0.1:' . free_port() . '/v1/traces', headers => {} },
      ( $mode ? ( 'TestPlugin::Later' => { mode => $mode } ) : () ),
    ],
  );
  my ($otel)  = grep { $_->isa('Langertha::Plugin::OTel') } @{ $chat->plugin_instances };
  my ($later) = grep { $_->isa('TestPlugin::Later') } @{ $chat->plugin_instances };
  return ( $chat, $otel, $later );
}

sub spans_of { my ($otel) = @_; return $json->decode( $otel->_otlp->to_json( $otel->_batch ) )->{resourceSpans}[0]{scopeSpans}[0]{spans} }
sub attrs_of { my ($span) = @_; return { map { $_->{key} => $_->{value} } @{ $span->{attributes} } } }
sub call_id  { my ($span) = @_; my $v = attrs_of($span)->{'gen_ai.tool.call.id'}; return $v ? $v->{stringValue} : undef }
sub secs     { my ( $span, $key ) = @_; return $span->{$key} / 1e9 }
sub tool_spans { my ($otel) = @_; return grep { $_->{name} =~ /\Aexecute_tool/ } @{ spans_of($otel) } }

my %LOOP = (
  sync  => sub { $_[0]->simple_chat_with_tools('go') },
  async => sub { $_[0]->simple_chat_with_tools_f('go')->get },
);

for my $loop ( sort keys %LOOP ) {

  subtest "$loop: two same-name, same-argument calls get their own start, end and call id" => sub {
    my ( $chat, $otel ) = chat_for( [ [ lookup => { query => 'x' } ], [ lookup => { query => 'x' } ] ] );
    is( $LOOP{$loop}->($chat), 'done', 'the loop answered' );
    my @tool = tool_spans($otel);
    is( scalar @tool, 2, 'two tool spans' );
    like( call_id( $tool[0] ), qr/\Acall_virtual_\d+\z/, 'first span has a call id' );
    like( call_id( $tool[1] ), qr/\Acall_virtual_\d+\z/, 'second span has a call id' );
    ok( call_id( $tool[0] ) lt call_id( $tool[1] ), 'ids in request order, distinct' );
    for my $span (@tool) {
      ok( secs( $span, 'startTimeUnixNano' ) < secs( $span, 'endTimeUnixNano' ), 'start before end' );
    }
    ok( secs( $tool[0], 'endTimeUnixNano' ) < secs( $tool[1], 'startTimeUnixNano' ),
      'the second span starts after the first ended: its own start, not the first call\'s' );
  };

  subtest "$loop: a call a later plugin skips leaves no start for the next one" => sub {
    my ( $chat, $otel, $later ) = chat_for(
      [ [ lookup => { query => 'x' } ], [ lookup => { query => 'x' } ] ], 'skip' );
    is( $LOOP{$loop}->($chat), 'done', 'the loop answered' );
    my @tool = tool_spans($otel);
    is( scalar @tool, 1, 'one tool span: the skipped call ran no tool' );
    my ($skipped_at) = @{ $later->acted };
    ok( secs( $tool[0], 'startTimeUnixNano' ) > $skipped_at,
      'the span starts after the skip, not at the skipped call\'s start' );
    is( call_id( $tool[0] ), 'call_virtual_2', 'the span names the call that ran, not the skipped one' );
    is( scalar keys %{ $otel->_call_starts }, 0, 'the skipped call\'s start went with its call HashRef' );
  };

  subtest "$loop: a call a later plugin renames keeps its start and its call id" => sub {
    my ( $chat, $otel, $later ) = chat_for(
      [ [ alias => { query => 'x' } ], [ lookup => { query => 'x' } ] ], 'rename' );
    is( $LOOP{$loop}->($chat), 'done', 'the loop answered' );
    my @tool = tool_spans($otel);
    is_deeply( [ map { $_->{name} } @tool ], [ 'execute_tool lookup', 'execute_tool lookup' ], 'both ran as lookup' );
    is_deeply( [ map { call_id($_) } @tool ], [ 'call_virtual_1', 'call_virtual_2' ], 'each span keeps its own call id' );
    for my $span (@tool) {
      ok( secs( $span, 'startTimeUnixNano' ) < secs( $span, 'endTimeUnixNano' ),
        'start before end: the renamed call found its start' );
    }
    ok( secs( $tool[0], 'endTimeUnixNano' ) < secs( $tool[1], 'startTimeUnixNano' ), 'spans do not overlap' );
  };
}

subtest 'interleaved same-name calls (parallel): each end pairs with its own start' => sub {
  my ( undef, $otel ) = chat_for( [] );
  my ( $call_a, $call_b ) = ( { id => 'a' }, { id => 'b' } );
  my %start;
  $otel->plugin_before_tool_call( 'lookup', { query => 'x' }, $call_a )->get; $start{a} = $clock;
  $otel->plugin_before_tool_call( 'lookup', { query => 'x' }, $call_b )->get; $start{b} = $clock;
  my ( $name, $input ) = $otel->plugin_before_tool_call( 'lookup', { query => 'x' }, { id => 'c' } )->get;
  is_deeply( [ $name, $input ], [ 'lookup', { query => 'x' } ], 'the call HashRef does not change what the hook returns' );
  $otel->plugin_after_tool_call( 'lookup', { query => 'x' }, 'r', $call_b )->get;
  $otel->plugin_after_tool_call( 'lookup', { query => 'x' }, 'r', $call_a )->get;
  my @tool = tool_spans($otel);
  is_deeply( [ map { call_id($_) } @tool ], [ 'b', 'a' ], 'call ids from the HashRef' );
  is_deeply( [ map { secs( $_, 'startTimeUnixNano' ) } @tool ], [ $start{b}, $start{a} ], 'each span starts at its own before hook' );
};

subtest 'hosts without the call HashRef (two / three arguments) still get spans and matched ids' => sub {
  my ( undef, $otel ) = chat_for( [] );
  $otel->plugin_before_llm_call( [ { role => 'user', content => 'go' } ], 1 )->get;
  my $response = Langertha::Response->new( content => '', tool_calls => [
    Langertha::ToolCall->new( id => 'c1', name => 'lookup', arguments => { query => 'x' } ),
    Langertha::ToolCall->new( id => 'c2', name => 'lookup', arguments => { query => 'y' } ),
  ] );
  $otel->plugin_after_llm_response( $response, 1 )->get;
  my @warnings;
  {
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    for my $query (qw( y x )) {
      my ( $name, $input ) = $otel->plugin_before_tool_call( 'lookup', { query => $query } )->get;
      is_deeply( [ $name, $input ], [ 'lookup', { query => $query } ], 'two-argument before hook returns the call' );
      is( $otel->plugin_after_tool_call( $name, $input, 'r' )->get, 'r', 'three-argument after hook returns the result' );
    }
  }
  is_deeply( \@warnings, [], 'no warnings' );
  my @tool = tool_spans($otel);
  is_deeply( [ map { call_id($_) } @tool ], [ 'c2', 'c1' ], 'call ids matched by name and arguments' );
  ok( secs( $_, 'startTimeUnixNano' ) < secs( $_, 'endTimeUnixNano' ), 'start before end' ) for @tool;
};

done_testing;
