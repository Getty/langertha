#!/usr/bin/env perl
# ABSTRACT: Langertha::Plugin::OTel flush over real LWP against a local HTTP::Daemon: request shape, failures never raise

use strict;
use warnings;

use Test2::Bundle::More;
use lib 't/lib';

BEGIN {
  plan skip_all => 'fork-based HTTP::Daemon test not supported on Windows' if $^O eq 'MSWin32';
}

use File::Temp ();
use HTTP::Response;
use IO::Socket::INET;
use JSON::MaybeXS;
use Test::LocalHTTPDaemon;

use Langertha::Chat;
use Langertha::Engine::Virtual;
use Langertha::Plugin::OTel;
use Langertha::Virtual::Rules qw( answer );

# A developer's own OpenTelemetry setup must not leak into the expectations.
delete @ENV{ grep { /\A OTEL_ /x } keys %ENV };

my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );

# The daemon is a forked process: it logs every request it sees as one JSON
# line to a file the test reads back.
my $log = File::Temp->new;
my $log_name = $log->filename;
my $mode = File::Temp->new;     # what the daemon answers: written by the test, read per request
my $mode_name = $mode->filename;

sub set_mode {
  my ($text) = @_;
  open my $fh, '>', $mode_name or die $!;
  print {$fh} $text;
  close $fh;
}

sub received {
  open my $fh, '<', $log_name or return ();
  my @lines = <$fh>;
  close $fh;
  return map { $json->decode($_) } @lines;
}

sub clear_log { open my $fh, '>', $log_name or die $!; close $fh }

my $server = Test::LocalHTTPDaemon->start( sub {
  my ($request) = @_;
  open my $out, '>>', $log_name or die $!;
  print {$out} $json->encode( {
    method => $request->method,
    path   => $request->uri->path,
    type   => scalar $request->header('Content-Type'),
    auth   => scalar $request->header('Authorization'),
    extra  => scalar $request->header('x-extra'),
    agent  => scalar $request->header('User-Agent'),
    body   => $request->content,
  } ), "\n";
  close $out;
  open my $in, '<', $mode_name or die $!;
  my $answer = do { local $/; <$in> } // '';
  close $in;
  return HTTP::Response->new( 500, 'Server Error', [ 'Content-Type' => 'text/plain' ], 'nope' ) if $answer eq 'fail';
  return HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'application/json' ],
    '{"partialSuccess":{"rejectedSpans":2,"errorMessage":"too old"}}' ) if $answer eq 'partial';
  return HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'application/json' ], '{}' );
} );
my $base = $server->url;

sub new_chat {
  my ( %plugin ) = @_;
  my $engine = Langertha::Engine::Virtual->new( langfuse_enabled => 0, fallback => answer('hello') );
  my $chat = Langertha::Chat->new( engine => $engine,
    plugins => [ OTel => { endpoint => "$base/v1/traces", %plugin } ] );
  my ($otel) = grep { $_->isa('Langertha::Plugin::OTel') } @{ $chat->plugin_instances };
  return ( $chat, $otel );
}

sub capture_warnings {
  my ($code) = @_;
  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, $_[0] };
  my @result = $code->();
  return ( \@warnings, @result );
}

subtest 'successful flush: POST, Content-Type, configured headers, body = payload' => sub {
  set_mode('ok');
  clear_log();
  my ( $chat, $otel ) = new_chat( headers => { Authorization => 'Basic dXNlcjpwdw==', 'x-extra' => 'yes' },
    service_name => 'flush-test' );
  $chat->simple_chat('one');
  $chat->simple_chat('two');
  my $expected = $json->decode( $otel->_otlp->to_json( $otel->_batch ) );
  is_deeply( scalar @{ $otel->_batch }, 2, 'two spans waiting' );

  my ( $warnings, $response ) = capture_warnings( sub { $otel->flush } );
  is_deeply( $warnings, [], 'no warnings on success' );
  ok( $response && $response->is_success, 'flush returns the HTTP::Response' );
  is_deeply( scalar @{ $otel->_batch }, 0, 'batch cleared' );

  my @requests = received();
  is_deeply( scalar @requests, 1, 'one request' );
  my $request = $requests[0];
  is_deeply( $request->{method}, 'POST', 'POST' );
  is_deeply( $request->{path}, '/v1/traces', 'to the endpoint path' );
  like( $request->{type}, qr{\Aapplication/json\b}, 'Content-Type application/json' );
  is_deeply( $request->{auth}, 'Basic dXNlcjpwdw==', 'Authorization header sent' );
  is_deeply( $request->{extra}, 'yes', 'custom header sent' );
  like( $request->{agent}, qr/Langertha/, 'identifying user agent' );
  my $payload = $json->decode( $request->{body} );
  is_deeply( $payload, $expected, 'the body decodes to the payload of the recorded spans' );
  is_deeply( scalar @{ $payload->{resourceSpans}[0]{scopeSpans}[0]{spans} }, 2, 'both spans in the request' );
  my %service = map { $_->{key} => $_->{value}{stringValue} } @{ $payload->{resourceSpans}[0]{resource}{attributes} };
  is_deeply( $service{'service.name'}, 'flush-test', 'service name in the resource' );

  clear_log();
  is_deeply( $otel->flush, undef, 'flush of an empty batch returns nothing' );
  is_deeply( scalar( () = received() ), 0, '... and sends nothing' );
};

subtest 'content type survives a user-supplied header casing' => sub {
  set_mode('ok');
  clear_log();
  my ( $chat, $otel ) = new_chat( headers => { 'content-type' => 'text/plain' } );
  $chat->simple_chat('x');
  $otel->flush;
  my ($request) = received();
  is_deeply( $request->{type}, 'application/json', 'exactly one Content-Type: application/json' );
};

subtest 'flush_batch_size splits one flush into several requests' => sub {
  set_mode('ok');
  clear_log();
  my ( $chat, $otel ) = new_chat( flush_batch_size => 2 );
  $chat->simple_chat("call $_") for 1 .. 5;
  $otel->flush;
  my @requests = received();
  is_deeply( scalar @requests, 3, 'five spans in chunks of two: three requests' );
  is_deeply( [ map { scalar @{ $json->decode( $_->{body} )->{resourceSpans}[0]{scopeSpans}[0]{spans} } } @requests ],
    [ 2, 2, 1 ], 'chunk sizes' );
};

subtest 'server error: warns, never raises, batch is gone' => sub {
  set_mode('fail');
  clear_log();
  my ( $chat, $otel ) = new_chat();
  my $text = $chat->simple_chat('hi');
  is_deeply( "$text", 'hello', 'the chat result is unaffected' );
  my ( $warnings, $ok ) = capture_warnings( sub { eval { $otel->flush; 1 } } );
  ok( $ok, 'flush did not die' );
  is_deeply( scalar @$warnings, 1, 'one warning' );
  like( $warnings->[0], qr/OTLP trace export failed: 500/, 'warning names the failure' );
  like( $warnings->[0], qr/1 span\(s\) lost/, '... and how many spans were lost' );
  is_deeply( scalar @{ $otel->_batch }, 0, 'batch cleared' );
};

subtest 'partialSuccess.rejectedSpans is warned about' => sub {
  set_mode('partial');
  my ( $chat, $otel ) = new_chat();
  $chat->simple_chat('a');
  $chat->simple_chat('b');
  my ( $warnings ) = capture_warnings( sub { $otel->flush } );
  is_deeply( scalar @$warnings, 1, 'one warning' );
  like( $warnings->[0], qr/2 of 2 span\(s\) rejected \(too old\)/, 'rejected count and the receiver message' );
};

subtest 'unreachable endpoint: warns, never raises, drops the rest quickly' => sub {
  my $closed = IO::Socket::INET->new( Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0 ) or die $!;
  my $port = $closed->sockport;
  close $closed;
  my ( $chat, $otel ) = new_chat( endpoint => "http://127.0.0.1:$port/v1/traces", flush_batch_size => 1,
    flush_timeout => 3 );
  my $text = $chat->simple_chat('x');
  $chat->simple_chat('y');
  $chat->simple_chat('z');
  is_deeply( "$text", 'hello', 'chat result unaffected' );
  my ( $warnings, $ok ) = capture_warnings( sub { eval { $otel->flush; 1 } } );
  ok( $ok, 'flush did not die' );
  ok( scalar @$warnings >= 1, 'warned' );
  like( join( '', @$warnings ), qr/OTLP trace export failed/, 'failure warned' );
  like( join( '', @$warnings ), qr/unreachable, dropping 2 more span\(s\)/, 'the rest of the flush is dropped, not retried' );
  is_deeply( scalar @{ $otel->_batch }, 0, 'batch cleared' );
};

subtest 'garbage endpoint does not raise' => sub {
  my ( $chat, $otel ) = new_chat( endpoint => 'not a url at all' );
  $chat->simple_chat('x');
  my ( $warnings, $ok ) = capture_warnings( sub { eval { $otel->flush; 1 } } );
  ok( $ok, 'flush did not die' );
  ok( scalar @$warnings, 'warned' );
};

subtest 'flush_f resolves and never fails' => sub {
  set_mode('ok');
  clear_log();
  my ( $chat, $otel ) = new_chat();
  $chat->simple_chat('x');
  my $future = $otel->flush_f;
  ok( $future->is_done, 'resolved (sync backend)' );
  my $response = $future->get;
  ok( $response->is_success, 'HTTP::Response' );
  is_deeply( scalar( () = received() ), 1, 'one request' );

  set_mode('fail');
  $chat->simple_chat('y');
  my ( $warnings, $failed ) = capture_warnings( sub { my $f = $otel->flush_f; $f->is_failed } );
  ok( !$failed, 'flush_f does not fail on a 500' );
  like( join( '', @$warnings ), qr/OTLP trace export failed: 500/, 'warned' );
};

subtest 'auto_flush: each call sends its spans, nothing blocks or raises' => sub {
  set_mode('ok');
  clear_log();
  my ( $chat, $otel ) = new_chat( auto_flush => 1 );
  my $text = $chat->simple_chat('one');
  is_deeply( "$text", 'hello', 'result' );
  $otel->flush;   # waits for anything still in flight
  my @requests = received();
  is_deeply( scalar @requests, 1, 'the span was sent without an explicit flush' );
  is_deeply( scalar @{ $otel->_batch }, 0, 'batch empty' );

  set_mode('fail');
  my ( $warnings, $result ) = capture_warnings( sub { my $r = eval { $chat->simple_chat('two') }; $otel->flush; $r } );
  is_deeply( "$result", 'hello', 'a failing endpoint does not touch the chat result' );
  like( join( '', @$warnings ), qr/OTLP trace export failed: 500/, 'warned' );
};

done_testing;
