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

  if ($on_header) {
    my $chunk_handler;
    my $response = $self->user_agent->request($request, sub {
      my ( $data, $resp ) = @_;
      $chunk_handler ||= $on_header->($resp);
      $chunk_handler->($data) if $chunk_handler;
    });
    $chunk_handler->(undef) if $chunk_handler;   # match the async end-of-body signal
    return Future->done($response);
  }

  my $response = $self->user_agent->request($request);
  return Future->done($response);
}

=method do_request

    my $future = $client->do_request( request => $http_request );

    my $future = $client->do_request(
      request   => $http_request,
      on_header => sub {
        my ($response) = @_;
        return sub { my ($data) = @_; ... };   # per-chunk, undef at end
      },
    );

Runs C<$http_request> synchronously through L</user_agent> and returns an
already-complete L<Future> resolving to the L<HTTP::Response>. No event loop
is involved: because the future is already ready, any C<await> on it (or
C<< ->get >>) resolves immediately, so the whole C<_f> chain runs
synchronously and sequentially.

When an C<on_header> callback is given the request streams: L<LWP::UserAgent>'s
per-chunk content callback is bridged to the contract — C<on_header> is called
once with the L<HTTP::Response> (headers) and returns a chunk-sub, which then
receives each body chunk as LWP reads it and finally C<undef> once to signal
end-of-body. LWP buffers before parsing, so delivery is sequential and blocking
rather than truly incremental, but each chunk still reaches the caller's
chunk-sub.

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
