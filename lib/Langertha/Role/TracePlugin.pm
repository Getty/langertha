package Langertha::Role::TracePlugin;
# ABSTRACT: Shared internals of the tracing plugins: JSON-safe snapshots and non-blocking flushes
our $VERSION = '0.506';
use Moose::Role;
use Scalar::Util qw( blessed refaddr weaken );

=head1 DESCRIPTION

The parts L<Langertha::Plugin::Langfuse> and L<Langertha::Plugin::OTel> share,
so both behave alike: how what a hook sees is copied into a trace without
image bytes, and how an C<auto_flush> leaves the call it runs in. Not meant
for consumption outside those plugins; nothing here is public API.

A consuming class (a L<Langertha::Plugin>, which has the C<host>) provides
C<_json> (a L<JSON::MaybeXS> object with
C<utf8>, C<canonical> and C<convert_blessed>), C<_flush_args> (the arguments
of one flush, taking the batch, or nothing when it is empty) and
C<_send_f> (a Future of the flush that never fails).

=cut

requires qw( host _json _flush_args _send_f );

has _pending_flushes => (
  is      => 'ro',
  default => sub { {} },
);

# Deep copy through the encoder: JSON-safe, and a Langertha::Content::Image
# becomes its compact TO_JSON description (never the image data). A Chat
# hands the hooks messages already in the engine's wire shape, where an image
# is a data: URL or a bare base64 string; those are shortened too, or every
# trace would carry every image once per iteration (as karr k273 for TO_JSON).
sub _json_safe {
  my ( $self, $data ) = @_;
  return $data unless ref $data;
  my $copy = eval { $self->_json->decode( $self->_json->encode($data) ) };
  return $data unless defined $copy;
  my $walk;
  $walk = sub {
    my ($node) = @_;
    my @slots = ref $node eq 'HASH' ? ( map { \$node->{$_} } keys %$node )
              : ref $node eq 'ARRAY' ? ( map { \$_ } @$node ) : ();
    for my $slot (@slots) {
      if ( ref $$slot ) { $walk->($$slot); next }
      next unless defined $$slot;
      if ( $$slot =~ m{\A(data:[^;,]+;base64,)(.*)\z}s ) {
        $$slot = $1 . '[' . _base64_bytes($2) . ' bytes omitted]';
      }
      elsif ( length $$slot >= 512 && $$slot =~ m{\A[A-Za-z0-9+/]+={0,2}\z} ) {
        $$slot = '[base64: ' . _base64_bytes($$slot) . ' bytes omitted]';
      }
    }
  };
  $walk->($copy);
  undef $walk;
  return $copy;
}

sub _base64_bytes {
  my ($b64) = @_;
  $b64 =~ s/\s+//g;
  my $pad = $b64 =~ /(=+)\z/ ? length $1 : 0;
  return int( length($b64) * 3 / 4 ) - $pad;
}

# The engine whose async backend carries a flush: the host when it is an
# engine itself, else the host's engine (Chat, Embedder, ImageGen, Raider).
# None (a host without one, or a host already gone: it is a weak ref) means
# the dedicated LWP agent with flush_timeout.
sub _flush_engine {
  my ( $self ) = @_;
  my $host = $self->host or return;
  return $host if $host->can('_async_do_request_f');
  return unless $host->can('engine');
  my $engine = $host->engine;
  return blessed($engine) && $engine->can('_async_do_request_f') ? $engine : undef;
}

# auto_flush from inside an async hook: start the flush and return at once.
# The future is held on the object until it is ready (flush_timeout bounds
# that), so it is not lost to garbage collection; flush / flush_f wait for it.
sub _auto_flush {
  my ( $self ) = @_;
  my %args = $self->_flush_args or return;
  my $future = $self->_send_f(%args);
  return if $future->is_ready;
  my $pending = $self->_pending_flushes;
  my $key     = refaddr $future;
  $pending->{$key} = $future;
  weaken( my $weak = $pending );
  $future->on_ready( sub { delete $weak->{$key} if $weak } );
  return;
}

# The blocking flush waits for auto_flush requests still in flight first.
# Only the Net::Async::HTTP path leaves a flush pending, so there is a loop.
sub _await_pending_flushes {
  my ( $self ) = @_;
  my @pending = values %{ $self->_pending_flushes } or return;
  my $engine = $self->_flush_engine;
  my $loop   = $engine ? $engine->async_loop : undef;
  $loop->await_all(@pending) if $loop;
  return;
}

=seealso

=over

=item * L<Langertha::Plugin::Langfuse> - Langfuse ingestion plugin

=item * L<Langertha::Plugin::OTel> - OpenTelemetry (OTLP) traces plugin

=back

=cut

1;
