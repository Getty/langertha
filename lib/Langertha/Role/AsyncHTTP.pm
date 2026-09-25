package Langertha::Role::AsyncHTTP;
# ABSTRACT: Async HTTP backend selection (injected > Net::Async::HTTP > sync LWP fallback)
our $VERSION = '0.503';
use Moose::Role;
use Future::AsyncAwait;

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
  my $loaded     = eval { require Net::Async::HTTP; 1 };
  my $load_error = $@;
  if ($loaded) {
    my $http = Net::Async::HTTP->new;
    $self->_async_loop->add($http);
    return $http;
  }
  unless ($WARNED) {
    $WARNED = 1;
    # A missing module is the expected, documented case. Anything else (a
    # missing IO::Async sub-dependency after a partial upgrade, a compile
    # error) is a broken install the user should see, not "not available".
    my $reason = $load_error =~ m{\ACan't locate Net/Async/HTTP\.pm }
      ? 'Net::Async::HTTP not available'
      : 'Net::Async::HTTP failed to load (' . ( split /\n/, $load_error )[0] . ')';
    warn "$reason; Langertha is running HTTP synchronously "
       . "(no concurrency). Install Net::Async::HTTP + IO::Async for real async."
       . _caller_location() . "\n";
  }
  require Langertha::Request::SyncHTTP;
  return Langertha::Request::SyncHTTP->new( user_agent => $self->user_agent );
}

# The builder runs inside a generated Moose accessor called from a Langertha
# role (chat_f, poll_metrics_f, ...), so carp would point into that plumbing.
# Report the first frame outside Langertha, Moose and the Future machinery:
# the user's own call site.
sub _caller_location {
  my $level = 0;
  while ( my ( $package, $file, $line ) = caller $level++ ) {
    next if $package =~ /\A(?:Langertha|Moose|Class::MOP|Eval::Closure|Future)(?:::|\z)/;
    return " at $file line $line.";
  }
  return '';
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
per process. The warning names the caller's own C<_f> call site; if
L<Net::Async::HTTP> is installed but fails to load (for example a missing
L<IO::Async> sub-dependency) it says so and includes the first line of the
load error instead of claiming the module is unavailable. The sync fallback runs HTTP B<synchronously and sequentially>
(blocking, no concurrency) — every C<_f> call still works and returns a
L<Future>, but multiple calls awaited "in parallel" run one after another.

=cut

async sub async_request_f {
  my ( $self, $request, %opts ) = @_;
  return await $self->_async_http->do_request( request => $request, %opts );
}

=method async_request_f

    my $response = await $engine->async_request_f($http_request);
    die $response->status_line unless $response->is_success;

    # streaming: on_header passes through to the backend
    await $engine->async_request_f($http_request, on_header => sub { ... });

Sends a prepared L<HTTP::Request> (for example from C<chat_request> or
C<build_tool_chat_request>) through the engine's selected backend
(L</_async_http>) and returns a L<Future> that resolves to the
L<HTTP::Response>. This is the public face of the C<do_request> contract, for
callers outside core that assemble their own requests: it behaves identically
on an injected client, L<Net::Async::HTTP> and the synchronous fallback
(where the returned future is already complete).

An HTTP error status B<resolves> the future — check C<is_success> on the
response; only a transport failure fails it. Any extra named options (such as
C<on_header> for streaming) are passed to C<do_request> unchanged. The backend
object itself is not exposed; see L</EVENT LOOP> for the loop question.

=cut

=head1 EVENT LOOP

Core promises no event loop: L<IO::Async> is only recommended, an injected
client may run on any loop, and the synchronous fallback runs on none. There is
deliberately no public loop accessor. A caller that needs a loop of its own
(to add notifiers, run timers, ...) brings it, and should obtain it with
C<< IO::Async::Loop->new >>: that constructor returns the process-wide loop,
which is also the one the default L<Net::Async::HTTP> backend is added to (see
L</_async_loop>), so both share one loop. A caller that injects an
L</_async_http> client on a different loop hands that same loop to whatever
else needs one.

=attr _async_loop

The L<IO::Async::Loop> the real-async client is added to. Built lazily and
B<only> on the L<Net::Async::HTTP> path; the sync fallback never touches it,
so no event loop is created when running synchronously. The default is
C<< IO::Async::Loop->new >>, the process-wide loop (see L</EVENT LOOP>).

=cut

1;
