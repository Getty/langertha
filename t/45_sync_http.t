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

done_testing;
