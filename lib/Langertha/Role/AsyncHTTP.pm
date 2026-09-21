package Langertha::Role::AsyncHTTP;
# ABSTRACT: Async HTTP backend selection (injected > Net::Async::HTTP > sync LWP fallback)
our $VERSION = '0.503';
use Moose::Role;
use Carp qw( carp );

requires 'user_agent';

my $WARNED = 0;

has _async_loop => (
  is => 'ro',
  lazy_build => 1,
);

sub _build__async_loop {
  require IO::Async::Loop;
  return IO::Async::Loop->new;
}

has _async_http => (
  is => 'ro',
  lazy_build => 1,
);

sub _build__async_http {
  my ($self) = @_;
  if ( eval { require Net::Async::HTTP; 1 } ) {
    my $http = Net::Async::HTTP->new;
    $self->_async_loop->add($http);
    return $http;
  }
  unless ($WARNED) {
    $WARNED = 1;
    carp "Net::Async::HTTP not available; Langertha is running HTTP synchronously "
       . "(no concurrency). Install Net::Async::HTTP + IO::Async for real async.";
  }
  require Langertha::Request::SyncHTTP;
  return Langertha::Request::SyncHTTP->new( user_agent => $self->user_agent );
}

=attr _async_http

The backend that satisfies the async C<do_request> contract:
C<< do_request( request => $req [, on_header => sub {...}] ) >> returning a
L<Future> that resolves to an L<HTTP::Response>. It is the injection seam —
pass C<< _async_http => $client >> at construction to bring your own client
(any object with that method) and it is used verbatim.

When not injected the builder selects, in order: L<Net::Async::HTTP> if it can
be loaded (a real async client added to L</_async_loop>); otherwise
L<Langertha::Request::SyncHTTP> over the engine's C<user_agent>, warning once
per process. The sync fallback runs HTTP B<synchronously and sequentially>
(blocking, no concurrency) — every C<_f> call still works and returns a
L<Future>, but multiple calls awaited "in parallel" run one after another.

=cut

=attr _async_loop

The L<IO::Async::Loop> the real-async client is added to. Built lazily and
B<only> on the L<Net::Async::HTTP> path; the sync fallback never touches it,
so no event loop is created when running synchronously.

=cut

1;
