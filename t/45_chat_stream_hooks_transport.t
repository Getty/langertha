#!/usr/bin/env perl
# ABSTRACT: Langertha::Chat streaming hooks over real transports (LWP, the sync shim, Net::Async::HTTP) against a local HTTP::Daemon: after-hook Response, failure hook with the error body, OTel spans
use strict;
use warnings;

use Test2::Bundle::More;

BEGIN {
  plan skip_all => 'fork-based HTTP::Daemon test not supported on Windows' if $^O eq 'MSWin32';
}

use Path::Tiny;
use IO::Socket::INET;
use HTTP::Response;
use JSON::MaybeXS;
use LWP::UserAgent;

use lib path(__FILE__)->parent->child('lib')->stringify;
use Test::LocalHTTPDaemon;

use Langertha::Chat;
use Langertha::Engine::OpenAI;
use Langertha::Request::SyncHTTP;

my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );

{
  package Test::Recorder;
  use Moose;
  use Future::AsyncAwait;
  extends 'Langertha::Plugin';
  has responses => ( is => 'ro', default => sub { [] } );
  has failures  => ( is => 'ro', default => sub { [] } );
  async sub plugin_after_llm_response {
    my ( $self, $data, $iteration, $call ) = @_;
    push @{ $self->responses }, [ $data, $call ];
    return $data;
  }
  async sub plugin_llm_call_failed {
    my ( $self, $error, $iteration, $call ) = @_;
    push @{ $self->failures }, [ $error, $call ];
    return;
  }
  __PACKAGE__->meta->make_immutable;
}

sub sse { return 'data: ' . $json->encode( $_[0] ) . "\n\n" }

# An OpenAI server: a stream with a trailing usage event, or a 429 with an
# OpenAI error body when the prompt asks for it.
my $server = Test::LocalHTTPDaemon->start( sub {
  my ($request) = @_;
  if ( $request->content =~ /limit me/ ) {
    return HTTP::Response->new( 429, 'Too Many Requests', [ 'Content-Type' => 'application/json' ],
      $json->encode( { error => { message => 'Rate limit reached', type => 'requests', code => 'rate_limit_exceeded' } } ) );
  }
  my @events = (
    sse( { id => 'chatcmpl-1', model => 'gpt-test-0001', choices => [ { index => 0, delta => { content => 'Hel' } } ] } ),
    sse( { id => 'chatcmpl-1', model => 'gpt-test-0001', choices => [ { index => 0, delta => { content => 'lo' } } ] } ),
    sse( { id => 'chatcmpl-1', model => 'gpt-test-0001', choices => [ { index => 0, delta => {}, finish_reason => 'stop' } ] } ),
    sse( { id => 'chatcmpl-1', model => 'gpt-test-0001', choices => [],
      usage => { prompt_tokens => 11, completion_tokens => 2, total_tokens => 13 } } ),
    "data: [DONE]\n\n",
  );
  return HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'text/event-stream' ], sub { shift(@events) // '' } );
} );
my $base = $server->url;

sub free_port {
  my $socket = IO::Socket::INET->new( Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0 ) or die $!;
  my $port = $socket->sockport;
  close $socket;
  return $port;
}

sub chat_for {
  my ( @engine_args ) = @_;
  my $chat = Langertha::Chat->new(
    engine  => Langertha::Engine::OpenAI->new( api_key => 'k', model => 'gpt-test', url => "$base/v1", @engine_args ),
    plugins => [ '+Test::Recorder',
      OTel => { endpoint => 'http://127.0.0.1:' . free_port() . '/v1/traces', headers => {} } ],
  );
  return ( $chat, @{ $chat->plugin_instances } );
}

sub span_attrs {
  my ($otel) = @_;
  my $spans = $json->decode( $otel->_otlp->to_json( $otel->_batch ) )->{resourceSpans}[0]{scopeSpans}[0]{spans};
  return [ map { my $span = $_; +{ status => $span->{status},
    map { $_->{key} => $_->{value} } @{ $span->{attributes} } } } @$spans ];
}

subtest 'sync simple_chat_stream over LWP' => sub {
  my ( $chat, $rec, $otel ) = chat_for();
  is( $chat->simple_chat_stream( sub { }, 'hi' ), 'Hello', 'streamed' );
  my ( $response, $call ) = @{ $rec->responses->[0] };
  is( $response->model, 'gpt-test-0001', 'the model the stream named' );
  is( $response->usage->input_tokens, 11, 'the trailing usage event' );
  is( $call->{http_response}->code, 200, 'the server answer' );

  ok( !eval { $chat->simple_chat_stream( sub { }, 'limit me' ); 1 }, 'a 429 dies' );
  my ( $error, $failed_call ) = @{ $rec->failures->[0] };
  like( $error, qr/streaming request failed: 429/, 'the engine error text' );
  like( $failed_call->{http_response}->content, qr/rate_limit_exceeded/, 'the hook got the error body' );

  my $spans = span_attrs($otel);
  is( scalar @$spans, 2, 'two spans' );
  is_deeply( $spans->[0]{'gen_ai.usage.input_tokens'}, { intValue => '11' }, 'usage on the stream span' );
  is_deeply( $spans->[1]{'error.type'}, { stringValue => 'rate_limit_exceeded' }, 'provider code on the error span' );
  is_deeply( $spans->[1]{status}, { code => 2 }, 'status ERROR' );
};

my @backends = ( [ 'sync LWP shim', sub {
  ( _async_http => Langertha::Request::SyncHTTP->new( user_agent => LWP::UserAgent->new( timeout => 10 ) ) ) } ] );
push @backends, [ 'Net::Async::HTTP', sub { () } ]
  if eval { require Net::Async::HTTP; require IO::Async::Loop; 1 };
note 'Net::Async::HTTP not installed: only the sync LWP shim runs' if @backends == 1;

for my $backend (@backends) {
  my ( $label, $args ) = @$backend;
  subtest "$label: simple_chat_stream_realtime_f" => sub {
    my ( $chat, $rec, $otel ) = chat_for( $args->() );
    my ( $content, undef, $timing ) = $chat->simple_chat_stream_realtime_f( undef, 'hi' )->get;
    is( $content, 'Hello', 'streamed' );
    my ( $response, $call ) = @{ $rec->responses->[0] };
    ok( $response->has_ttft, 'the Response carries the ttft' );
    is( $response->usage->input_tokens, 11, 'and the usage' );
    ok( $call->{stream}, 'stream flag' );

    my $f = $chat->simple_chat_stream_realtime_f( undef, 'limit me' );
    $f->await;
    ok( $f->is_failed, 'a 429 fails the future' );
    like( ( $f->failure )[0], qr/streaming request failed: 429.*Rate limit reached/, 'with the engine error text' );
    my ( $error, $failed_call ) = @{ $rec->failures->[0] };
    is( $error, ( $f->failure )[0], 'the hook saw the same error' );
    is( $failed_call->{http_response}->code, 429, 'the 429' );
    like( $failed_call->{http_response}->content, qr/rate_limit_exceeded/, 'with its body, also on the async backend' );

    my $spans = span_attrs($otel);
    is( scalar @$spans, 2, 'two spans' );
    is_deeply( $spans->[0]{'gen_ai.request.stream'}, { boolValue => JSON::MaybeXS::true() }, 'stream true' );
    is( $spans->[0]{'gen_ai.response.time_to_first_chunk'}{doubleValue}, $timing->{ttft_seconds}, 'ttft on the span' );
    is_deeply( $spans->[1]{'error.type'}, { stringValue => 'rate_limit_exceeded' }, 'provider code on the error span' );
  };
}

done_testing;
