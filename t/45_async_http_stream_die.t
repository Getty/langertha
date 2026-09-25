#!/usr/bin/env perl
# ABSTRACT: a die in the streaming chunk callback fails that request's future on Net::Async::HTTP, not the event loop
use strict; use warnings;
use Test2::Bundle::More;
use FindBin;
use lib "$FindBin::Bin/lib";

BEGIN {
  plan skip_all => 'fork-based HTTP::Daemon test not supported on Windows' if $^O eq 'MSWin32';
  eval { require Future::AsyncAwait; 1 }
    or plan skip_all => 'Requires Future::AsyncAwait';
  eval { require Net::Async::HTTP; require IO::Async::Loop; 1 }
    or plan skip_all => 'Requires Net::Async::HTTP and IO::Async (the async backend under test)';
}

use Future;
use HTTP::Response;
use JSON::MaybeXS;
use LWP::UserAgent;
use Test::LocalHTTPDaemon;
use Langertha::Request::SyncHTTP;
use Langertha::Engine::OpenAI;

# On the Net::Async::HTTP backend the chunk callback runs inside the IO::Async
# loop's read handler. A die there (a malformed stream line, or the user's
# chunk_callback) used to unwind out of the loop into whatever happened to be
# driving it: the request's own future stayed pending, and in an application
# that runs one loop for everything, unrelated work died with it. The sync
# shim has always failed the request future instead. (karr k194, ADR 0027)

my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );
my @DELTAS = ( 'Hel', 'lo ', 'world' );

sub sse_event { 'data: ' . $json->encode({ choices => [ { index => 0, delta => { content => $_[0] } } ] }) . "\n\n" }

# One event per HTTP chunk with a pause in between, so body is still pending
# on the socket when the first chunk callback dies.
sub chunked_sse {
  my @events = @_;
  my $first  = 1;
  return HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'text/event-stream' ], sub {
    select( undef, undef, undef, 0.2 ) unless $first;
    $first = 0;
    return shift(@events) // '';
  });
}

my $server = Test::LocalHTTPDaemon->start(sub {
  my ($request) = @_;
  my $path = $request->uri->path;
  my @done = (
    'data: ' . $json->encode({ choices => [ { index => 0, delta => {}, finish_reason => 'stop' } ] }) . "\n\n",
    "data: [DONE]\n\n",
  );
  return chunked_sse( ( map { sse_event($_) } @DELTAS ), @done ) if $path =~ m{^/ok/};
  return chunked_sse( sse_event('Hel'), "data: {not json\n\n", sse_event('lo '), @done )
    if $path =~ m{^/malformed/};
  return HTTP::Response->new( 404, 'Not Found', [ 'Content-Type' => 'text/plain' ], 'no route' );
});
my $base = $server->url;

sub engine {
  my ( $prefix, %args ) = @_;
  return Langertha::Engine::OpenAI->new(
    api_key => 'test-key',
    model   => 'gpt-test',
    url     => "$base/$prefix/v1",
    %args,
  );
}

sub stream_f {
  my ( $engine, $chunk_callback ) = @_;
  return $engine->chat_stream_realtime_f(
    messages => [ { role => 'user', content => 'hi' } ],
    ( $chunk_callback ? ( chunk_callback => $chunk_callback ) : () ),
  );
}

my $loop = IO::Async::Loop->new;

# Drive the shared loop until every future is ready (or a safety timeout
# fires). Returns whatever escaped the loop, '' when nothing did.
sub drive {
  my @futures = @_;
  my $all     = Future->wait_all(@futures);
  my $timeout = $loop->delay_future( after => 15 );
  my $escaped = eval { $loop->await( Future->wait_any( $all, $timeout ) ); 1 } ? '' : $@;
  return $escaped;
}

subtest 'user chunk_callback dies: that request fails, a concurrent one on the same loop completes' => sub {
  my $engine = engine('ok');
  ok( $engine->_async_http->isa('Net::Async::HTTP'), 'engine runs on the Net::Async::HTTP backend' );
  is( $engine->_async_loop, $loop, 'engine shares the process loop' );

  my $calls     = 0;
  my $dying     = stream_f( $engine, sub { $calls++; die "user abort\n" } );
  my $bystander = stream_f( engine('ok') );

  is( drive( $dying, $bystander ), '', 'no exception escaped the event loop' );
  ok( $dying->is_ready, 'the dying request future is ready' );
  ok( $dying->is_failed, 'the dying request future failed' );
  is( ( $dying->failure )[0], "user abort\n", 'with the original exception' );
  is( $calls, 1, 'chunk_callback was not called again after it died' );
  ok( $bystander->is_done, 'the concurrent request on the same loop completed' );
  is( ( $bystander->get )[0], 'Hello world', 'with its full content' );

  my $next = stream_f($engine);
  is( drive($next), '', 'a following request on the same engine runs without an escaped exception' );
  ok( $next->is_done, 'the following request completed' );
  is( ( $next->get )[0], 'Hello world', 'the following request streamed its full content' );
};

subtest 'malformed stream line: the request fails with the parser error, same as the sync shim' => sub {
  my $engine = engine('malformed');
  my $seen   = [];
  my $future = stream_f( $engine, sub { push @$seen, $_[0]->content } );

  is( drive($future), '', 'no exception escaped the event loop' );
  ok( $future->is_failed, 'the request future failed' );
  my $async_error = ( $future->failure )[0];
  ok( length $async_error, 'with the parser exception' );
  is_deeply( $seen, ['Hel'], 'the chunk before the malformed line was delivered, none after' );

  my $sync = stream_f( engine( 'malformed',
    _async_http => Langertha::Request::SyncHTTP->new( user_agent => LWP::UserAgent->new( timeout => 10 ) ) ) );
  ok( $sync->is_failed, 'the sync shim fails the same request' );
  is( $async_error, ( $sync->failure )[0], 'same exception on both backends' );

  my $next = stream_f( engine('ok') );
  is( drive($next), '', 'a following request runs without an escaped exception' );
  is( ( $next->get )[0], 'Hello world', 'the following request streamed its full content' );
};

done_testing;
