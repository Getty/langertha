#!/usr/bin/env perl
# ABSTRACT: Langertha::Request::SyncHTTP satisfies the do_request contract over LWP, sync
use strict; use warnings;
use Test2::Bundle::More;
use HTTP::Response;
use HTTP::Request;
use Langertha::Request::SyncHTTP;

# Mock UA: no content callback -> returns a canned HTTP::Response
{
  package MockUA;
  use Moose;
  has calls => (is => 'ro', default => sub { [] });
  sub request {
    my ($self, $request, $content_cb) = @_;
    push @{$self->calls}, $request;
    my $response = HTTP::Response->new(200, 'OK', [ 'Content-Type' => 'text/plain' ], 'hello');
    return $response;
  }
  __PACKAGE__->meta->make_immutable;
}

my $client = Langertha::Request::SyncHTTP->new( user_agent => MockUA->new );
my $future = $client->do_request( request => HTTP::Request->new(GET => 'http://x/') );
isa_ok($future, ['Future'], 'do_request returns a Future');
ok($future->is_ready, 'future is already complete (no loop needed)');
my $response = $future->get;
is($response->code, 200, 'resolves to the HTTP::Response');
is($response->decoded_content, 'hello', 'body present');

# Streaming mock UA: invokes the content callback per chunk, LWP-style ($data, $response)
{
  package MockStreamUA;
  use Moose;
  has chunks => (is => 'ro', default => sub { [qw(foo bar baz)] });
  sub request {
    my ($self, $request, $content_cb) = @_;
    my $response = HTTP::Response->new(200, 'OK', [ 'Content-Type' => 'text/event-stream' ]);
    $content_cb->($_, $response) for @{$self->chunks};   # LWP: ($data, $response, $protocol)
    return $response;
  }
  __PACKAGE__->meta->make_immutable;
}

my @seen; my $header_response; my $end_seen = 0;
my $sclient = Langertha::Request::SyncHTTP->new( user_agent => MockStreamUA->new );
my $sfuture = $sclient->do_request(
  request   => HTTP::Request->new(GET => 'http://x/stream'),
  on_header => sub {
    my ($response) = @_;
    $header_response = $response;
    return sub { my ($data) = @_; defined $data ? push(@seen, $data) : $end_seen++ };
  },
);
ok($sfuture->is_ready, 'streaming future already complete');
is($header_response->code, 200, 'on_header got the response');
is_deeply(\@seen, [qw(foo bar baz)], 'chunks delivered incrementally, in order');
is($end_seen, 1, 'end-of-body signalled once with undef');
is($sfuture->get->code, 200, 'future resolves to the response');

done_testing;
