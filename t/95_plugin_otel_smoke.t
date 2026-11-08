#!/usr/bin/env perl
# ABSTRACT: Smoke test for Langertha::Plugin::OTel on a virtual engine's tool loop (no network)

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
use Langertha::Virtual::Rules qw( answer tool after );

my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );

my $calculator = Test::MockMCP->new(
  tools => [ {
    name         => 'add',
    description  => 'Add two numbers',
    input_schema => { type => 'object', properties => { a => { type => 'number' }, b => { type => 'number' } } },
    code => sub { my ( $self, $args ) = @_; return $self->text_result( $args->{a} + $args->{b} ) },
  } ],
);

# A port nothing listens on: bound, then closed again.
sub free_port {
  my $socket = IO::Socket::INET->new( Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0 ) or die $!;
  my $port = $socket->sockport;
  close $socket;
  return $port;
}

sub run_loop {
  my (%plugin_args) = @_;
  my $engine = Langertha::Engine::Virtual->new(
    langfuse_enabled => 0,
    rules => [
      qr/\AAdd (\d+) and (\d+)\z/ => sub { tool( add => { a => $_[1], b => $_[2] } ) },
      after('add') => sub { answer( 'The secret sum is ' . $_[0]{tool_results}[0]{content} . '.' ) },
    ],
    fallback => answer('I can only add.'),
  );
  my $otel = Langertha::Plugin::OTel->new( host => $engine, endpoint => 'http://127.0.0.1:' . free_port() . '/v1/traces',
    headers => {}, %plugin_args );
  my $chat = Langertha::Chat->new( engine => $engine, mcp_servers => [$calculator], plugins => [$otel] );
  my $text = $chat->simple_chat_with_tools('Add 2 and 3');
  my $body = $otel->_otlp->to_json( $otel->_batch );
  return ( $text, $otel, $body, $json->decode($body) );
}

subtest 'tool loop: chat, tool, chat spans in one trace; content stays out by default' => sub {
  my ( $text, $otel, $body, $payload ) = run_loop();
  is( $text, 'The secret sum is 5.', 'the loop answered' );
  my $scope = $payload->{resourceSpans}[0]{scopeSpans}[0];
  is( $scope->{schemaUrl}, 'https://opentelemetry.io/schemas/1.41.1', 'semconv pinned' );
  my @spans = @{ $scope->{spans} };
  is( scalar @spans, 3, 'two LLM calls and one tool call' );
  my %traces = map { $_->{traceId} => 1 } @spans;
  is( scalar keys %traces, 1, 'one trace' );
  my ($tool) = grep { $_->{name} eq 'execute_tool add' } @spans;
  ok( $tool, 'execute_tool span' );
  is( $tool->{parentSpanId}, $spans[0]{spanId}, 'tool span is a child of the first chat span' );
  is( $spans[0]{kind}, 3, 'chat span is CLIENT' );
  is( $tool->{kind}, 1, 'tool span is INTERNAL' );
  my %attr = map { $_->{key} => $_->{value} } @{ $tool->{attributes} };
  ok( $attr{'gen_ai.tool.call.id'}, 'tool call id matched' );
  unlike( $body, qr/secret|Add 2 and 3/, 'no prompt or answer text in the payload' );
  like( $spans[0]{startTimeUnixNano}, qr/\A\d{19}\z/, 'nanos as decimal string' );
};

subtest 'capture_content puts the messages in' => sub {
  my ( $text, $otel, $body, $payload ) = run_loop( capture_content => 1, session_id => 's-1' );
  like( $body, qr/secret sum/, 'answer captured' );
  like( $body, qr/Add 2 and 3/, 'prompt captured' );
  like( $body, qr/session\.id/, 'session id' );
};

subtest 'flush to an unreachable endpoint warns, never dies' => sub {
  my ( $text, $otel ) = run_loop();
  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, $_[0] };
  my $ok = eval { $otel->flush; 1 };
  ok( $ok, 'flush did not die' );
  like( join( '', @warnings ), qr/OTLP trace export failed/, 'failure warned' );
  is( scalar @{ $otel->_batch }, 0, 'batch cleared' );
};

done_testing;
