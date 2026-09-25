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
    # No HTTP/1.1 pipelining: a request pipelined behind a long LLM stream
    # waits for it anyway, and fails with "Connection closed" when that stream
    # is aborted (karr k199, ADR 0027).
    my $http = Net::Async::HTTP->new( pipeline => 0 );
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
be loaded (a real async client added to L</_async_loop>, built with
C<< pipeline => 0 >>); otherwise
L<Langertha::Request::SyncHTTP> over the engine's C<user_agent>, warning once
per process. The warning names the caller's own C<_f> call site; if
L<Net::Async::HTTP> is installed but fails to load (for example a missing
L<IO::Async> sub-dependency) it says so and includes the first line of the
load error instead of claiming the module is unavailable. The sync fallback runs HTTP B<synchronously and sequentially>
(blocking, no concurrency) — every C<_f> call still works and returns a
L<Future>, but multiple calls awaited "in parallel" run one after another.

The L<Net::Async::HTTP> client does not pipeline HTTP/1.1 requests: a request
pipelined behind a long LLM stream would wait for it anyway, and would fail
with C<Connection closed> if that stream were cancelled or aborted. It keeps
the library's other defaults, including C<max_connections_per_host> (one
keep-alive connection per host; the C<NET_ASYNC_HTTP_MAXCONNS> environment
variable changes it), so concurrent requests on one engine are sent one after
another on that connection. Concurrent requests through different engines use
their own clients. Inject a client configured otherwise to change either.

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
callers outside core that assemble their own requests. On the synchronous
fallback the returned future is already complete.

An HTTP error status (4xx/5xx) B<resolves> the future on every backend: check
C<is_success> on the response. A B<transport-level> failure (connection
refused, DNS, timeout) is B<not> uniform across backends: on
L<Net::Async::HTTP> it B<fails> the future with the socket error, while on the
synchronous fallback it B<resolves> with the 500 response LWP synthesizes
(C<500 Can't connect ...>, header C<Client-Warning: Internal response>) — the
future does not fail. Either way the call did not succeed, so always check
C<is_success>; do not rely on a failed future alone to catch a dead endpoint.
See ADR 0027 for the parity scope.

Any extra named options (such as C<on_header> for streaming) are passed to
C<do_request> unchanged. The backend object itself is not exposed; see
L</async_loop> for the event loop.

=cut

sub async_loop {
  my ($self) = @_;
  my $http = $self->_async_http;
  return $http->can('loop') ? $http->loop : undef;
}

=method async_loop

    my $loop = $engine->async_loop // IO::Async::Loop->new;
    $loop->add($notifier);
    await $loop->delay_future( after => 2 );

Returns the event loop of the active async backend (L</_async_http>), or
C<undef> — a C<Maybe[loop]>. Core promises no loop (see L</EVENT LOOP>):

=over 4

=item * an injected client that has a C<loop> method: that client's loop,
whatever loop the caller put it on;

=item * the default L<Net::Async::HTTP> backend: the loop it was added to
(L</_async_loop>);

=item * the synchronous fallback (L<Langertha::Request::SyncHTTP>) or an
injected client without a C<loop> method: C<undef>.

=back

Calling it selects the backend if that has not happened yet (so on a clean
install it may emit the one-time fallback warning). Code that needs a loop for
its own notifiers or timers should use this loop when it is defined, so its
futures and the engine's HTTP futures are driven by the same loop; awaiting
futures from two different loops in one chain can hang.

=cut

=head1 EVENT LOOP

Core promises no event loop: L<IO::Async> is only recommended, an injected
client may run on any loop, and the synchronous fallback runs on none.
L</async_loop> reports the backend's loop when there is one and C<undef>
otherwise. When it is C<undef> a caller that needs a loop brings its own,
typically C<< IO::Async::Loop->new >> (the process-wide loop).

The backend's loop is not necessarily the process-wide one: an injected
L</_async_http> client can live on any loop, and L</_async_loop> is itself a
constructor argument (C<< _async_loop => $my_loop >>), in which case the
default L<Net::Async::HTTP> backend is added to that loop. L</async_loop>
returns the right loop in all of these cases.

=attr _async_loop

The L<IO::Async::Loop> the real-async client is added to. Built lazily and
B<only> on the L<Net::Async::HTTP> path; the sync fallback never touches it,
so no event loop is created when running synchronously. The default is
C<< IO::Async::Loop->new >>, the process-wide loop; it can be passed at
construction to put the default backend on another loop (see L</EVENT LOOP>).
Use L</async_loop> to read the backend's loop.

=cut

1;
