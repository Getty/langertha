package Langertha::Plugin::Langfuse;
# ABSTRACT: Langfuse observability plugin for any PluginHost
our $VERSION = '0.503';
use Moose;
use Future::AsyncAwait;
use Time::HiRes qw( gettimeofday );
use Carp qw( croak );
use JSON::MaybeXS ();
use Future;
use Scalar::Util qw( blessed refaddr weaken );

extends 'Langertha::Plugin';

=head1 SYNOPSIS

    use Langertha::Chat;
    use Langertha::Plugin::Langfuse;

    my $langfuse = Langertha::Plugin::Langfuse->new(
        public_key => 'pk-lf-...',
        secret_key => 'sk-lf-...',
    );

    my $chat = Langertha::Chat->new(
        engine  => $engine,
        plugins => [$langfuse],
    );

    $chat->simple_chat('Hello!');
    $langfuse->flush;

Or with sugar:

    my $chat = Langertha::Chat->new(
        engine  => $engine,
        plugins => [Langfuse => {
            trace_name => 'my-chat',
            auto_flush => 1,
        }],
    );

Environment variables C<LANGFUSE_PUBLIC_KEY>, C<LANGFUSE_SECRET_KEY>, and
C<LANGFUSE_URL> are auto-populated when not explicitly set.

=head1 DESCRIPTION

This plugin integrates any L<Langertha::Role::PluginHost> (L<Langertha::Chat>,
L<Langertha::Embedder>, L<Langertha::Raider>) with
L<Langfuse|https://langfuse.com/> observability. It hooks into the standard
plugin events to automatically create traces, generations, and spans.

Unlike L<Langertha::Role::Langfuse> (which lives on the engine), this plugin
works on any PluginHost and does not require engine-level configuration.

=cut

has public_key => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  default => sub { $ENV{LANGFUSE_PUBLIC_KEY} // '' },
);

=attr public_key

Langfuse project public key. Defaults to C<LANGFUSE_PUBLIC_KEY> env var.

=cut

has secret_key => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  default => sub { $ENV{LANGFUSE_SECRET_KEY} // '' },
);

=attr secret_key

Langfuse project secret key. Defaults to C<LANGFUSE_SECRET_KEY> env var.

=cut

has url => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  default => sub { $ENV{LANGFUSE_URL} // 'https://cloud.langfuse.com' },
);

=attr url

Langfuse API URL. Defaults to C<LANGFUSE_URL> env var or
C<https://cloud.langfuse.com>.

=cut

has enabled => (
  is      => 'ro',
  isa     => 'Bool',
  lazy    => 1,
  builder => '_build_enabled',
);

=attr enabled

Whether Langfuse integration is active. Defaults to true when both
C<public_key> and C<secret_key> are non-empty.

=cut

sub _build_enabled {
  my ( $self ) = @_;
  return length($self->public_key) && length($self->secret_key) ? 1 : 0;
}

has trace_name => (
  is      => 'ro',
  isa     => 'Str',
  default => 'llm-call',
);

=attr trace_name

Name for the Langfuse trace created per chat session. Defaults to
C<'llm-call'>.

=cut

has user_id => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_user_id',
);

=attr user_id

Optional user ID passed to the Langfuse trace.

=cut

has session_id => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_session_id',
);

=attr session_id

Optional session ID passed to the Langfuse trace.

=cut

has tags => (
  is        => 'ro',
  isa       => 'ArrayRef[Str]',
  predicate => 'has_tags',
);

=attr tags

Optional tags passed to the Langfuse trace.

=cut

has metadata => (
  is        => 'ro',
  isa       => 'HashRef',
  predicate => 'has_metadata',
);

=attr metadata

Optional metadata HashRef merged into the Langfuse trace.

=cut

has auto_flush => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

=attr auto_flush

When true, the batch is sent after each C<plugin_after_llm_response>,
C<plugin_after_image_gen> and C<plugin_after_embedding>. Defaults to false.

The hook does not wait for Langfuse. With the L<Net::Async::HTTP> backend the
flush runs in the background on the host engine's event loop, bounded by
L</flush_timeout>, and the call returns at once; a slow or unreachable
Langfuse costs the chat nothing. The request only makes progress while that
loop runs, so a synchronous program should call L</flush> before it exits:
that waits for flushes still in flight and sends what is left. Without
L<Net::Async::HTTP> (or without an engine on the host) everything is
synchronous anyway and the hook sends right away, again bounded by
L</flush_timeout>.

=cut

has flush_timeout => (
  is      => 'ro',
  isa     => 'Num',
  default => 10,
);

=attr flush_timeout

Seconds a flush may wait for Langfuse per request. Default C<10>: an
ingestion endpoint that accepts the connection and never answers must not
hold up the application. The engine's C<user_agent_timeout> does not apply to
flushes. On the L<Net::Async::HTTP> backend it is the total time of the
request, on the LWP path the time without activity on the connection.

=cut

has flush_batch_size => (
  is      => 'ro',
  isa     => 'Int',
  default => 100,
);

=attr flush_batch_size

The most events sent in one ingestion request. Default C<100>; a larger batch
goes out as several requests, one after another.

=cut

has _pending_flushes => (
  is      => 'ro',
  default => sub { {} },
);

# --- Internal state ---

has _batch => (
  is      => 'rw',
  isa     => 'ArrayRef',
  default => sub { [] },
);

has max_batch => (
  is      => 'ro',
  isa     => 'Int',
  default => 1000,
);

=attr max_batch

The most events kept in memory between two flushes. Default C<1000>. When the
batch is full the B<oldest> event is dropped for each new one, with a single
warning per plugin object; C<0> removes the cap. Without L</auto_flush> the
events are only sent by L</flush>, so this bounds what a process that never
flushes holds.

=cut

# Every event goes through here so the batch stays bounded (karr k305).
sub _push {
  my ( $self, $event ) = @_;
  my $batch = $self->_batch;
  push @$batch, $event;
  my $max = $self->max_batch;
  if ( $max > 0 && @$batch > $max ) {
    splice @$batch, 0, @$batch - $max;
    unless ( $self->{_overflow_warned}++ ) {
      warn ref($self) . ": Langfuse batch reached max_batch ($max events) without a flush; "
         . "dropping the oldest events. Call flush regularly or set auto_flush.\n";
    }
  }
  return;
}

has _trace_id => (
  is  => 'rw',
  isa => 'Maybe[Str]',
);

has _iter_start => (
  is  => 'rw',
  isa => 'Maybe[Str]',
);

has _json => (
  is      => 'ro',
  lazy    => 1,
  default => sub { JSON::MaybeXS->new(utf8 => 1, canonical => 1, convert_blessed => 1) },
);

# --- Langfuse utility methods ---

sub _id {
  my @hex = map { sprintf("%04x", int(rand(65536))) } 1..8;
  return join('-',
    $hex[0].$hex[1],
    $hex[2],
    '4'.substr($hex[3], 1),
    sprintf("%x", 8 + int(rand(4))).substr($hex[4], 1),
    $hex[5].$hex[6].$hex[7],
  );
}

sub _timestamp {
  my ($s, $us) = gettimeofday;
  my @t = gmtime($s);
  return sprintf("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
    $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0], int($us/1000));
}

# --- Langfuse event creation ---

sub create_trace {
  my ( $self, %opts ) = @_;
  return unless $self->enabled;
  my $id = $opts{id} || _id();
  $self->_push({
    id        => _id(),
    type      => 'trace-create',
    timestamp => _timestamp(),
    body      => {
      id   => $id,
      name => $opts{name} // 'langfuse-trace',
      $opts{input}       ? ( input       => $opts{input} )       : (),
      $opts{output}      ? ( output      => $opts{output} )      : (),
      $opts{metadata}    ? ( metadata    => $opts{metadata} )    : (),
      $opts{tags}        ? ( tags        => $opts{tags} )        : (),
      $opts{user_id}     ? ( userId      => $opts{user_id} )     : (),
      $opts{session_id}  ? ( sessionId   => $opts{session_id} )  : (),
    },
  });
  return $id;
}

=method create_trace

    my $trace_id = $plugin->create_trace(name => 'my-trace', input => {...});

Creates a trace event. Returns the trace ID. Called automatically by
the plugin hooks, but can also be used manually.

=cut

sub create_generation {
  my ( $self, %opts ) = @_;
  return unless $self->enabled;
  my $id = $opts{id} || _id();
  $self->_push({
    id        => _id(),
    type      => 'generation-create',
    timestamp => _timestamp(),
    body      => {
      id       => $id,
      traceId  => $opts{trace_id} // croak("create_generation requires trace_id"),
      name     => $opts{name} // 'generation',
      $opts{model}                ? ( model              => $opts{model} )              : (),
      $opts{input}                ? ( input              => $opts{input} )              : (),
      $opts{output}               ? ( output             => $opts{output} )             : (),
      $opts{usage}                ? ( usage              => $opts{usage} )              : (),
      $opts{start_time}           ? ( startTime          => $opts{start_time} )         : (),
      $opts{end_time}             ? ( endTime            => $opts{end_time} )           : (),
      $opts{parent_observation_id}? ( parentObservationId => $opts{parent_observation_id} ) : (),
      $opts{model_parameters}     ? ( modelParameters    => $opts{model_parameters} )   : (),
    },
  });
  return $id;
}

=method create_generation

    $plugin->create_generation(trace_id => $id, model => 'gpt-4o', ...);

Creates a generation event linked to a trace.

=cut

sub create_span {
  my ( $self, %opts ) = @_;
  return unless $self->enabled;
  my $id = $opts{id} || _id();
  $self->_push({
    id        => _id(),
    type      => 'span-create',
    timestamp => _timestamp(),
    body      => {
      id      => $id,
      traceId => $opts{trace_id} // croak("create_span requires trace_id"),
      $opts{name}                 ? ( name               => $opts{name} )               : (),
      $opts{input}                ? ( input              => $opts{input} )              : (),
      $opts{output}               ? ( output             => $opts{output} )             : (),
      $opts{start_time}           ? ( startTime          => $opts{start_time} )         : (),
      $opts{end_time}             ? ( endTime            => $opts{end_time} )           : (),
      $opts{parent_observation_id}? ( parentObservationId => $opts{parent_observation_id} ) : (),
      $opts{metadata}             ? ( metadata           => $opts{metadata} )           : (),
    },
  });
  return $id;
}

=method create_span

    $plugin->create_span(trace_id => $id, name => 'tool-call', ...);

Creates a span event within a trace.

=cut

sub update_trace {
  my ( $self, %opts ) = @_;
  return unless $self->enabled;
  my $id = $opts{id} // croak("update_trace requires id");
  $self->_push({
    id        => _id(),
    type      => 'trace-create',
    timestamp => _timestamp(),
    body      => {
      id => $id,
      $opts{output}   ? ( output   => $opts{output} )   : (),
      $opts{metadata} ? ( metadata => $opts{metadata} )  : (),
    },
  });
  return $id;
}

=method update_trace

    $plugin->update_trace(id => $trace_id, output => 'result');

Updates a trace by upserting with the same ID.

=cut

sub _flush_args {
  my ( $self ) = @_;
  my @events = @{ $self->_batch };
  return unless @events;
  $self->_batch([]);
  my $size = $self->flush_batch_size;
  $size = 1 if $size < 1;
  my @chunks;
  push @chunks, [ splice @events, 0, $size ] while @events;
  return (
    chunks     => \@chunks,
    url        => $self->url,
    public_key => $self->public_key,
    secret_key => $self->secret_key,
    json       => $self->_json,
    agent      => 'Langertha-Plugin-Langfuse/' . $VERSION,
    timeout    => $self->flush_timeout,
  );
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

sub _send_f {
  my ( $self, %args ) = @_;
  require Langertha::Role::Langfuse;
  return Langertha::Role::Langfuse->_langfuse_send_chunks_f( %args, engine => $self->_flush_engine );
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

sub flush {
  my ( $self ) = @_;
  return unless $self->enabled;
  if ( my @pending = values %{ $self->_pending_flushes } ) {
    # Only the Net::Async::HTTP path leaves a flush pending, so there is a loop.
    my $engine = $self->_flush_engine;
    my $loop   = $engine ? $engine->async_loop : undef;
    $loop->await_all(@pending) if $loop;
  }
  my %args = $self->_flush_args or return;
  require Langertha::Role::Langfuse;
  my @responses = Langertha::Role::Langfuse->_langfuse_send_chunks_f(%args)->get;
  return $responses[-1];
}

=method flush

    $plugin->flush;

Sends all batched events to the Langfuse ingestion API over a dedicated
L<LWP::UserAgent> with L</flush_timeout>, and clears the batch. Blocks until
done; first it waits for any L</auto_flush> request still in flight. Do not
call it from inside an event loop; use L</flush_f> there. More than
L</flush_batch_size> events go out as several requests. Returns the
L<HTTP::Response> of the last request, or nothing when there was nothing to
send.

It never dies. It warns when a request fails (its events are lost, and after
a timeout or refused connection the rest of the flush is dropped too) and when
Langfuse answers C<207 Multi-Status> with per-event C<errors> (the number
rejected and the first error).

=cut

async sub flush_f {
  my ( $self ) = @_;
  return unless $self->enabled;
  my @pending = values %{ $self->_pending_flushes };
  await Future->wait_all(@pending) if @pending;
  my %args = $self->_flush_args or return;
  return await $self->_send_f(%args);
}

=method flush_f

    await $plugin->flush_f;

Async L</flush>: waits for L</auto_flush> requests still in flight, then
sends the batch through the host engine's async backend
(L<Langertha::Role::AsyncHTTP>) with L</flush_timeout> as each request's total
timeout, so a slow or silent Langfuse never blocks the event loop. Resolves
to the L<HTTP::Response> of each request and B<never fails>; problems are
warned about as in L</flush>. Without an engine on the host, or on the
synchronous fallback, it runs like L</flush>.

=cut

sub reset_trace {
  my ( $self ) = @_;
  $self->_trace_id(undef);
  $self->_iter_start(undef);
}

=method reset_trace

    $plugin->reset_trace;

Resets the current trace state. Call this between independent chat
sessions to start a new trace.

=cut

=seealso

=over

=item * L<Langertha::Plugin> - Base class with all hook method signatures

=item * L<Langertha::Role::PluginHost> - Plugin system consumed by hosts

=item * L<Langertha::Chat> - Chat host this plugin attaches to

=item * L<Langertha::Embedder> - Embedder host this plugin attaches to

=item * L<Langertha::ImageGen> - Image generation host this plugin attaches to

=item * L<Langertha::Raider> - Autonomous agent host this plugin attaches to

=item * L<https://langfuse.com/> - Langfuse observability platform

=back

=cut

# --- Plugin hooks ---

async sub plugin_before_llm_call {
  my ( $self, $conversation, $iteration ) = @_;
  return $conversation unless $self->enabled;

  # Create trace on first iteration (or if no trace exists)
  if (!$self->_trace_id) {
    $self->_trace_id($self->create_trace(
      name => $self->trace_name,
      input => $conversation,
      $self->has_user_id    ? ( user_id    => $self->user_id )    : (),
      $self->has_session_id ? ( session_id => $self->session_id ) : (),
      $self->has_tags       ? ( tags       => $self->tags )       : (),
      $self->has_metadata   ? ( metadata   => $self->metadata )   : (),
    ));
  }

  $self->_iter_start(_timestamp());
  return $conversation;
}

async sub plugin_after_llm_response {
  my ( $self, $data, $iteration ) = @_;
  return $data unless $self->enabled;

  # Create generation event
  my $end_time = _timestamp();
  $self->create_generation(
    trace_id   => $self->_trace_id,
    name       => "generation-$iteration",
    start_time => $self->_iter_start,
    end_time   => $end_time,
  );

  # Update trace output (last update wins via upsert)
  $self->update_trace(
    id     => $self->_trace_id,
    output => $data,
  );

  $self->_auto_flush if $self->auto_flush;

  return $data;
}

async sub plugin_after_tool_call {
  my ( $self, $name, $input, $result ) = @_;
  return $result unless $self->enabled;

  my $t = _timestamp();
  $self->create_span(
    trace_id   => $self->_trace_id,
    name       => "tool:$name",
    input      => $input,
    output     => $result,
    start_time => $t,
    end_time   => $t,
  );

  return $result;
}

async sub plugin_before_image_gen {
  my ( $self, $prompt ) = @_;
  return $prompt unless $self->enabled;

  if (!$self->_trace_id) {
    $self->_trace_id($self->create_trace(
      name  => $self->trace_name,
      input => $prompt,
      $self->has_user_id    ? ( user_id    => $self->user_id )    : (),
      $self->has_session_id ? ( session_id => $self->session_id ) : (),
      $self->has_tags       ? ( tags       => $self->tags )       : (),
      $self->has_metadata   ? ( metadata   => $self->metadata )   : (),
    ));
  }

  $self->_iter_start(_timestamp());
  return $prompt;
}

async sub plugin_after_image_gen {
  my ( $self, $prompt, $result ) = @_;
  return $result unless $self->enabled;

  my $end_time = _timestamp();
  $self->create_generation(
    trace_id   => $self->_trace_id,
    name       => 'image-generation',
    start_time => $self->_iter_start,
    end_time   => $end_time,
    input      => $prompt,
  );

  $self->update_trace(
    id     => $self->_trace_id,
    output => $result,
  );

  $self->_auto_flush if $self->auto_flush;

  return $result;
}

async sub plugin_before_embedding {
  my ( $self, $text ) = @_;
  return $text unless $self->enabled;

  if (!$self->_trace_id) {
    $self->_trace_id($self->create_trace(
      name  => $self->trace_name,
      input => $text,
      $self->has_user_id    ? ( user_id    => $self->user_id )    : (),
      $self->has_session_id ? ( session_id => $self->session_id ) : (),
      $self->has_tags       ? ( tags       => $self->tags )       : (),
      $self->has_metadata   ? ( metadata   => $self->metadata )   : (),
    ));
  }

  $self->_iter_start(_timestamp());
  return $text;
}

async sub plugin_after_embedding {
  my ( $self, $text, $vector ) = @_;
  return $vector unless $self->enabled;

  my $end_time = _timestamp();
  $self->create_generation(
    trace_id   => $self->_trace_id,
    name       => 'embedding',
    start_time => $self->_iter_start,
    end_time   => $end_time,
    input      => $text,
  );

  $self->update_trace(
    id     => $self->_trace_id,
    # A batch (k289) is an ArrayRef of vectors: report the vector's width.
    output => { dimensions => ref $vector eq 'ARRAY'
      ? ( ref $vector->[0] eq 'ARRAY' ? scalar @{$vector->[0]} : scalar @$vector )
      : undef },
  );

  $self->_auto_flush if $self->auto_flush;

  return $vector;
}

__PACKAGE__->meta->make_immutable;

1;
