#!/usr/bin/env perl
# ABSTRACT: the tool hooks get a trailing call HashRef with the tool call id, the same one for every plugin and both hooks; two-argument callers keep working

use strict;
use warnings;

use Test2::Bundle::More;
use Path::Tiny;
use Scalar::Util qw( refaddr );

use lib path(__FILE__)->parent->child('lib')->stringify;

use Test::MockMCP;

use Langertha::Chat;
use Langertha::Engine::Virtual;
use Langertha::Virtual::Rules qw( answer tools );

{
  package TestPlugin::Recorder;
  use Moose;
  use Future::AsyncAwait;
  extends 'Langertha::Plugin';
  has before_calls => ( is => 'ro', default => sub { [] } );
  has after_calls  => ( is => 'ro', default => sub { [] } );
  async sub plugin_before_tool_call {
    my ( $self, @args ) = @_;
    push @{ $self->before_calls }, [@args];
    return @args[ 0, 1 ];
  }
  async sub plugin_after_tool_call {
    my ( $self, @args ) = @_;
    push @{ $self->after_calls }, [@args];
    return $args[2];
  }
  __PACKAGE__->meta->make_immutable;
}

{
  # Written for the two-argument hook, and returning whatever it got.
  package TestPlugin::Legacy;
  use Moose;
  use Future::AsyncAwait;
  extends 'Langertha::Plugin';
  async sub plugin_before_tool_call {
    my ( $self, $name, $input ) = @_;
    return ( $name, $input );
  }
  __PACKAGE__->meta->make_immutable;
}

my $mcp = Test::MockMCP->new( tools => [
  { name => 'lookup', description => 'Look something up',
    input_schema => { type => 'object', properties => { query => { type => 'string' } } },
    code => sub { my ( $self ) = @_; return $self->text_result('found') } },
] );

sub chat {
  my $engine = Langertha::Engine::Virtual->new(
    langfuse_enabled => 0,
    rules            => [ qr/\Ago\z/ => sub { tools( [ [ lookup => { query => 'x' } ], [ lookup => { query => 'x' } ] ] ) } ],
    fallback         => answer('done'),
  );
  return Langertha::Chat->new(
    engine      => $engine,
    mcp_servers => [$mcp],
    plugins     => [ 'TestPlugin::Recorder', 'TestPlugin::Legacy', 'TestPlugin::Recorder' ],
  );
}

my %LOOP = (
  sync  => sub { $_[0]->simple_chat_with_tools('go') },
  async => sub { $_[0]->simple_chat_with_tools_f('go')->get },
);

for my $loop ( sort keys %LOOP ) {
  subtest "$loop tool loop: every plugin gets the same call HashRef in both hooks" => sub {
    my $chat = chat();
    is( $LOOP{$loop}->($chat), 'done', 'the loop answered' );
    my ( $first, undef, $last ) = @{ $chat->plugin_instances };
    is( scalar @{ $first->before_calls }, 2, 'two calls reached the before hook' );
    for my $i ( 0, 1 ) {
      my $before = $first->before_calls->[$i];
      is( scalar @$before, 3, 'before hook: name, input, call' );
      is( $before->[0], 'lookup', 'the name' );
      is_deeply( $before->[1], { query => 'x' }, 'the input' );
      is_deeply( $before->[2], { id => 'call_virtual_' . ( $i + 1 ) }, 'the call HashRef carries the tool call id' );
      my $call = $before->[2];
      is( refaddr( $last->before_calls->[$i][2] ), refaddr($call), 'a later plugin (after a two-argument one) gets the same HashRef' );
      is( scalar @{ $first->after_calls->[$i] }, 4, 'after hook: name, input, result, call' );
      is( refaddr( $_->after_calls->[$i][3] ), refaddr($call), 'the after hook gets the same HashRef' ) for $first, $last;
    }
    isnt( refaddr( $first->before_calls->[0][2] ), refaddr( $first->before_calls->[1][2] ), 'one HashRef per call' );
  };
}

subtest 'plugin_pipeline_tool_call_f with two arguments: plugins see two arguments' => sub {
  my $chat = chat();
  my @result = $chat->plugin_pipeline_tool_call_f( 'lookup', { query => 'x' } )->get;
  is_deeply( \@result, [ 'lookup', { query => 'x' } ], 'returns the name and input' );
  is_deeply( $chat->plugin_instances->[0]->before_calls, [ [ 'lookup', { query => 'x' } ] ], 'no call argument added' );
};

subtest 'plugin_pipeline_tool_call_f with the call HashRef: passed on, never returned' => sub {
  my $chat = chat();
  my $call = { id => 'c1' };
  my @result = $chat->plugin_pipeline_tool_call_f( 'lookup', { query => 'x' }, $call )->get;
  is_deeply( \@result, [ 'lookup', { query => 'x' } ], 'returns only the name and input' );
  is( refaddr( $_->before_calls->[0][2] ), refaddr($call), 'each recording plugin got it' )
    for @{ $chat->plugin_instances }[ 0, 2 ];
};

done_testing;
