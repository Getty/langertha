package Langertha::Request::SyncHTTP;
# ABSTRACT: Synchronous LWP-backed HTTP client satisfying the async do_request contract
our $VERSION = '0.503';
use Moose;
use Future;

has user_agent => (
  is => 'ro',
  required => 1,
);

=attr user_agent

The synchronous HTTP client used to run the request, normally an
L<LWP::UserAgent>. Any object with a
C<< ->request($http_request [, $content_cb]) >> method that returns an
L<HTTP::Response> satisfies the contract. Required.

=cut

sub do_request {
  my ( $self, %args ) = @_;
  my $request   = $args{request};
  my $on_header = $args{on_header};

  # (streaming branch added in Task 2)

  my $response = $self->user_agent->request($request);
  return Future->done($response);
}

=method do_request

    my $future = $client->do_request( request => $http_request );

Runs C<$http_request> synchronously through L</user_agent> and returns an
already-complete L<Future> resolving to the L<HTTP::Response>. No event loop
is involved: because the future is already ready, any C<await> on it (or
C<< ->get >>) resolves immediately, so the whole C<_f> chain runs
synchronously and sequentially.

This is the drop-in fallback backend for the async C<do_request> contract
(L<Langertha::Role::AsyncHTTP>): HTTP error statuses (4xx/5xx) B<resolve>
with the response — they do not fail the future — so the caller checks
C<< $response->is_success >>, exactly as with L<Net::Async::HTTP>.

=cut

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Role::AsyncHTTP> - Backend selection that falls back to this shim

=item * L<Langertha::Role::HTTP> - Provides the C<user_agent> this shim runs over

=back

=cut

1;
