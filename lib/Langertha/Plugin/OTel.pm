package Langertha::Plugin::OTel;
# ABSTRACT: OpenTelemetry traces (OTLP/HTTP JSON, GenAI semantic conventions) for any PluginHost
our $VERSION = '0.506';
use Moose;
use Future::AsyncAwait;
use JSON::MaybeXS ();
use Future;
use Hash::Util::FieldHash ();
use Scalar::Util qw( blessed );
use Time::HiRes ();
use Langertha::Role::Langfuse ();
use Langertha::Trace::OTLP;

extends 'Langertha::Plugin';

=head1 SYNOPSIS

To an OpenTelemetry Collector (or anything else that receives OTLP/HTTP):

    use Langertha::Chat;

    my $chat = Langertha::Chat->new(
        engine  => $engine,
        plugins => [ OTel => {
            endpoint     => 'http://localhost:4318/v1/traces',
            service_name => 'my-app',
        } ],
    );

    $chat->simple_chat('Hello!');

    my ($otel) = grep { $_->isa('Langertha::Plugin::OTel') } @{ $chat->plugin_instances };
    $otel->flush;

Or configured from the standard OpenTelemetry environment variables
(C<OTEL_EXPORTER_OTLP_ENDPOINT>, C<OTEL_EXPORTER_OTLP_HEADERS>,
C<OTEL_SERVICE_NAME>, ...):

    my $chat = Langertha::Chat->new(
        engine  => $engine,
        plugins => [ OTel => { auto_flush => 1 } ],
    );

To Langfuse's OTLP endpoint (Basic auth with the project's public and secret
key):

    use MIME::Base64 qw( encode_base64 );

    my $chat = Langertha::Chat->new(
        engine  => $engine,
        plugins => [ OTel => {
            endpoint => 'https://cloud.langfuse.com/api/public/otel/v1/traces',
            headers  => {
                Authorization => 'Basic ' . encode_base64( "$public_key:$secret_key", '' ),
                'x-langfuse-ingestion-version' => '4',
            },
            session_id      => $conversation_id,   # Langfuse groups traces by session.id
            capture_content => 1,                  # opt in: prompts and answers
            auto_flush      => 1,
        } ],
    );

For a self-hosted Langfuse use its host name in place of
C<cloud.langfuse.com>.

=head1 DESCRIPTION

This plugin records the calls of any L<Langertha::Role::PluginHost>
(L<Langertha::Chat>, L<Langertha::Embedder>, L<Langertha::ImageGen>, an
engine, or the Raider of the langertha-raider distribution) as OpenTelemetry
spans and sends them as OTLP/HTTP JSON to a traces endpoint. The payload is
built by L<Langertha::Trace::OTLP>; it needs no OpenTelemetry SDK.

B<Semantic conventions version.> The spans follow the OpenTelemetry GenAI
semantic conventions of release B<v1.41.1>
(L<https://github.com/open-telemetry/semantic-conventions/blob/v1.41.1/docs/gen-ai/gen-ai-spans.md>),
named in every payload as C<schemaUrl> C<https://opentelemetry.io/schemas/1.41.1>.
The GenAI conventions are marked I<Development> and change between releases,
so the version is pinned. v1.41.1 is the last release that carries them:
v1.42.0 deprecated every C<gen_ai.*> attribute in favour of a separate GenAI
conventions project that has no release yet. When it has one, the attribute
names may change with a later version of this module.

B<What is recorded.> One trace per conversation: every span shares the trace
id until L</reset_trace>. There is no root span; the spans of the LLM calls
are the top level of the trace.

=over 4

=item * Each LLM call is a C<CLIENT> span C<chat {model}> from
C<plugin_before_llm_call> to C<plugin_after_llm_response>, with
C<gen_ai.operation.name> C<chat>, C<gen_ai.provider.name> (see
L<Langertha::Trace::OTLP/provider_name>), C<gen_ai.request.model>,
C<server.address> and C<server.port>, the request parameters set on the
engine (temperature, max tokens, seed; C<gen_ai.output.type> C<json> with a
C<response_format>), and from the answer C<gen_ai.response.id>,
C<gen_ai.response.model>, C<gen_ai.response.finish_reasons>, the token usage
and, when known, C<gen_ai.response.time_to_first_chunk>
(L<Langertha::Trace::OTLP/response_attributes>). In a tool loop the hook gets
the provider's raw reply; it is read with the engine's
C<tool_loop_response>, as the loop itself reads it.

=item * A streamed call (L<Langertha::Chat/simple_chat_stream>,
L<Langertha::Chat/simple_chat_stream_realtime_f>) is the same span, ended when
the stream has: it also carries C<gen_ai.request.stream> C<true> and, from
the realtime method, C<gen_ai.response.time_to_first_chunk> (seconds). The
response attributes come from what the stream delivered: model, finish
reason, and the token usage when the provider sent it in the stream (some
send it only on request). A stream carries no C<gen_ai.response.id>.

=item * A failed call (see L<Langertha::Chat/FAILED CALLS>) ends its span
with status C<ERROR> and C<error.type>: the provider's error code when its
error answer names one (OpenAI's C<error.code> or C<error.type>, Anthropic's
C<error.type>, Google's C<error.status>), else the class of an exception
object, else the HTTP status of an error answer (C<429>), else C<_OTHER>.
The error message becomes the status message only with
L</capture_content>: it often quotes the provider's answer, and with it parts
of the prompt.

=item * Each tool call of a tool loop is an C<INTERNAL> span
C<execute_tool {name}>, a child of the LLM call that asked for it, with
C<gen_ai.tool.name>, C<gen_ai.tool.type> C<function> and
C<gen_ai.tool.call.id>. It runs from C<plugin_before_tool_call> to
C<plugin_after_tool_call>, paired by the call HashRef the host passes both
hooks (see L<Langertha::Plugin/HOOK METHODS>), whose C<id> is the call id: a
call another plugin renames keeps its span, and one it skips leaves no start
behind. A host that passes no call HashRef (such as L<Langertha::Raider>)
gets the start of the oldest open call of that name and the call id of the
requested call with the same name and arguments. A result
marked C<isError> sets the span status to error with C<error.type>
C<_OTHER>.

=item * An embedding (L<Langertha::Embedder>) is a C<CLIENT> span
C<embeddings {model}> with C<gen_ai.embeddings.dimension.count>; an image
generation (L<Langertha::ImageGen>) is C<generate_content {model}> with
C<gen_ai.output.type> C<image>. Called through C<simple_embedding_result> /
C<simple_image_result> (or their C<_f>) they also carry the model that
answered and the token usage, from the L<Langertha::CallResult>.

=back

With L</session_id>, every span carries it as C<gen_ai.conversation.id> and
C<session.id>.

B<Content.> By default no content leaves the process: no prompt, answer,
system prompt, tool argument or tool result appears anywhere in the payload,
only the metadata above. L</capture_content> opts in.

B<Not recorded.> A failure on a host that does not fire
C<plugin_llm_call_failed> leaves no span: its open span is dropped by the next
call. The engines' own chat methods fire no plugin hooks, so only calls made
through a host are recorded.

=cut

has endpoint => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  builder => '_build_endpoint',
);

sub _build_endpoint {
  my $traces = $ENV{OTEL_EXPORTER_OTLP_TRACES_ENDPOINT};
  return $traces if defined $traces && length $traces;
  my $base = $ENV{OTEL_EXPORTER_OTLP_ENDPOINT};
  if ( defined $base && length $base ) {
    $base =~ s{/+\z}{};
    return "$base/v1/traces";
  }
  return 'http://localhost:4318/v1/traces';
}

=attr endpoint

The full URL spans are POSTed to. Defaults to
C<OTEL_EXPORTER_OTLP_TRACES_ENDPOINT> as it is, else
C<OTEL_EXPORTER_OTLP_ENDPOINT> with C</v1/traces> appended, else
C<http://localhost:4318/v1/traces> (a local Collector).

=cut

has headers => (
  is      => 'ro',
  isa     => 'HashRef[Str]',
  lazy    => 1,
  builder => '_build_headers',
);

sub _build_headers {
  return {
    _parse_key_values( $ENV{OTEL_EXPORTER_OTLP_HEADERS} ),
    _parse_key_values( $ENV{OTEL_EXPORTER_OTLP_TRACES_HEADERS} ),
  };
}

=attr headers

HashRef of extra request headers, such as C<Authorization>. Defaults to
C<OTEL_EXPORTER_OTLP_HEADERS> merged with C<OTEL_EXPORTER_OTLP_TRACES_HEADERS>
(the latter wins), both in the OpenTelemetry format: comma-separated
C<key=value> pairs with percent-encoded values. Given explicitly, the
environment is not read.

=cut

has resource_attributes => (
  is      => 'ro',
  isa     => 'HashRef',
  default => sub { {} },
);

=attr resource_attributes

HashRef of resource attributes (C<service.version>,
C<deployment.environment.name>, ...). They are merged over the ones in
C<OTEL_RESOURCE_ATTRIBUTES> (same format as the headers).

=cut

has service_name => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  builder => '_build_service_name',
);

sub _build_service_name {
  my ( $self ) = @_;
  my $explicit = $self->resource_attributes->{'service.name'};
  return $explicit if defined $explicit && !ref $explicit && length $explicit;
  my $env = $ENV{OTEL_SERVICE_NAME};
  return $env if defined $env && length $env;
  my $from_resource = $self->_resource->{'service.name'};
  return $from_resource if defined $from_resource && length $from_resource;
  return 'unknown_service:perl';
}

=attr service_name

The C<service.name> resource attribute. Defaults to a C<service.name> given in
L</resource_attributes>, else C<OTEL_SERVICE_NAME>, else a C<service.name> in
C<OTEL_RESOURCE_ATTRIBUTES>, else C<unknown_service:perl>. What is set in the
constructor wins over the environment.

=cut

has enabled => (
  is      => 'ro',
  isa     => 'Bool',
  default => 1,
);

=attr enabled

Whether spans are recorded and sent. Default true.

=cut

has capture_content => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

=attr capture_content

Default false. When true, the content of the calls is recorded as JSON-string
attributes in the shape the conventions define: C<gen_ai.input.messages> (the
conversation sent, system messages included as C<system> role messages),
C<gen_ai.output.messages> (the answer, with its tool calls), and on tool spans
C<gen_ai.tool.call.arguments> and C<gen_ai.tool.call.result>; an image
generation's prompt is its C<gen_ai.input.messages>. Images are never sent:
a L<Langertha::Content::Image> appears as its compact description, inline
image data (a C<data:> URL or a long bare base64 string) as its size, as in
L<Langertha::Plugin::Langfuse>.

Prompts and answers often hold personal or confidential data; turn this on
only for a trace backend that may hold them.

=cut

has session_id => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_session_id',
);

=attr session_id

Optional id of the conversation, sent on every span as
C<gen_ai.conversation.id> and C<session.id>. Nothing is sent without one.

=cut

has provider_name => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_provider_name',
);

=attr provider_name

Optional C<gen_ai.provider.name> for every span, instead of the one derived
from the engine class (L<Langertha::Trace::OTLP/provider_name>). Useful for
an engine pointed at another provider's compatible endpoint.

=cut

has auto_flush => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

=attr auto_flush

When true, the spans are sent after each C<plugin_after_llm_response>,
C<plugin_llm_call_failed>, C<plugin_after_embedding> and
C<plugin_after_image_gen>. Default false.

The hook does not wait for the endpoint. With the L<Net::Async::HTTP> backend
the flush runs in the background on the host engine's event loop, bounded by
L</flush_timeout>, and the call returns at once. The request only makes
progress while that loop runs, so a synchronous program should call
L</flush> before it exits. Without L<Net::Async::HTTP> (or without an engine
on the host) the hook sends right away, bounded by L</flush_timeout>.

=cut

has flush_timeout => (
  is      => 'ro',
  isa     => 'Num',
  default => 10,
);

=attr flush_timeout

Seconds a flush may wait for the endpoint per request. Default C<10>. On the
L<Net::Async::HTTP> backend it is the total time of the request, on the LWP
path the time without activity on the connection.

=cut

has flush_batch_size => (
  is      => 'ro',
  isa     => 'Int',
  default => 100,
);

=attr flush_batch_size

The most spans sent in one request. Default C<100>; more go out as several
requests, one after another.

=cut

has max_batch => (
  is      => 'ro',
  isa     => 'Int',
  default => 1000,
);

=attr max_batch

The most spans kept in memory between two flushes. Default C<1000>. When it
is full the B<oldest> span is dropped for each new one, with a single warning
per plugin object; C<0> removes the cap.

=cut

# --- Internal state ---

has _batch => (
  is      => 'rw',
  isa     => 'ArrayRef',
  default => sub { [] },
);

has _trace_id     => ( is => 'rw', isa => 'Maybe[Str]' );
has _llm_span     => ( is => 'rw', isa => 'Maybe[HashRef]' );
has _parent_id    => ( is => 'rw', isa => 'Maybe[Str]' );
has _op_start     => ( is => 'rw', isa => 'Maybe[Num]' );
has _tool_starts  => ( is => 'rw', isa => 'HashRef', default => sub { {} } );
has _tool_ids     => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );

# Tool starts keyed by the hooks' call HashRef. A field hash drops an entry
# when its HashRef is freed, so a call that never reaches
# plugin_after_tool_call (skipped, or no such tool) leaves nothing behind.
has _call_starts => (
  is      => 'ro',
  isa     => 'HashRef',
  default => sub { Hash::Util::FieldHash::fieldhash( my %starts ); return \%starts },
);

has _resource => (
  is      => 'ro',
  isa     => 'HashRef',
  lazy    => 1,
  default => sub {
    my ( $self ) = @_;
    return { _parse_key_values( $ENV{OTEL_RESOURCE_ATTRIBUTES} ), %{ $self->resource_attributes } };
  },
);

has _otlp => (
  is      => 'ro',
  lazy    => 1,
  default => sub {
    my ( $self ) = @_;
    return Langertha::Trace::OTLP->new(
      service_name        => $self->service_name,
      resource_attributes => $self->_resource,
      scope_version       => $VERSION,
    );
  },
);

# For the role's JSON-safe snapshots (bytes in, bytes out).
has _json => (
  is      => 'ro',
  lazy    => 1,
  default => sub { JSON::MaybeXS->new( utf8 => 1, canonical => 1, convert_blessed => 1 ) },
);

# For the JSON-string attributes: characters, the payload encoder makes UTF-8.
has _json_text => (
  is      => 'ro',
  lazy    => 1,
  default => sub {
    JSON::MaybeXS->new( utf8 => 0, canonical => 1, convert_blessed => 1, allow_nonref => 1 );
  },
);

my $protocol_warned;

sub BUILD {
  my ( $self ) = @_;
  for my $var (qw( OTEL_EXPORTER_OTLP_TRACES_PROTOCOL OTEL_EXPORTER_OTLP_PROTOCOL )) {
    my $protocol = $ENV{$var};
    next unless defined $protocol && length $protocol;
    warn "$var is '$protocol'; " . __PACKAGE__ . " only sends http/json\n"
      if $protocol ne 'http/json' && !$protocol_warned++;
    last;
  }
  return;
}

# OpenTelemetry's key=value,key=value environment format (W3C Baggage style),
# values percent-decoded.
sub _parse_key_values {
  my ( $text ) = @_;
  return () unless defined $text && length $text;
  my @pairs;
  for my $item ( split /,/, $text ) {
    my ( $key, $value ) = split /=/, $item, 2;
    next unless defined $value;
    s/\A\s+//, s/\s+\z// for $key, $value;
    next unless length $key;
    $value =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
    push @pairs, $key => $value;
  }
  return @pairs;
}

sub _now { Time::HiRes::time() }

# Every span goes through here so the batch stays bounded.
sub _push {
  my ( $self, $span ) = @_;
  my $batch = $self->_batch;
  push @$batch, $span;
  my $max = $self->max_batch;
  if ( $max > 0 && @$batch > $max ) {
    splice @$batch, 0, @$batch - $max;
    unless ( $self->{_overflow_warned}++ ) {
      warn ref($self) . ": OTLP span batch reached max_batch ($max spans) without a flush; "
         . "dropping the oldest spans. Call flush regularly or set auto_flush.\n";
    }
  }
  return;
}

sub _trace {
  my ( $self ) = @_;
  return $self->_trace_id // $self->_trace_id( Langertha::Trace::OTLP->new_trace_id );
}

sub _session_attributes {
  my ( $self ) = @_;
  return () unless $self->has_session_id;
  return ( 'gen_ai.conversation.id' => $self->session_id, 'session.id' => $self->session_id );
}

sub _host_engine {
  my ( $self ) = @_;
  my $host = $self->host or return;
  return $host->engine if $host->can('engine') && blessed( $host->engine );
  return $host;
}

# A wrapper's own model / temperature (Chat, Embedder, ImageGen); not the
# engine's, when the engine is the host.
sub _host_override {
  my ( $self, $attr ) = @_;
  my $host = $self->host or return;
  return unless $host->can('engine');
  my $has = "has_$attr";
  return $host->can($has) && $host->$has ? $host->$attr : undef;
}

sub _request_attributes {
  my ( $self, $operation ) = @_;
  my $model       = $self->_host_override('model');
  my $temperature = $operation eq 'chat' ? $self->_host_override('temperature') : undef;
  return (
    Langertha::Trace::OTLP->request_attributes( scalar $self->_host_engine,
      operation => $operation,
      defined $model       ? ( model         => $model )             : (),
      defined $temperature ? ( temperature   => $temperature )       : (),
      $self->has_provider_name ? ( provider_name => $self->provider_name ) : (),
    ),
    $self->_session_attributes,
  );
}

sub _span_name {
  my ( $operation, $attr ) = @_;
  my $model = $attr->{'gen_ai.request.model'};
  return defined $model && length $model ? "$operation $model" : $operation;
}

sub _json_string {
  my ( $self, $data ) = @_;
  my $text = eval { $self->_json_text->encode($data) };
  return $text;
}

# Compares a tool call's arguments with what plugin_after_tool_call got.
# Every leaf as a string: a tool that did arithmetic on its arguments has
# numified them in place, which would change their JSON.
sub _arguments_key {
  my ( $self, $arguments ) = @_;
  my $strings;
  $strings = sub {
    my ($node) = @_;
    return { map { $_ => $strings->( $node->{$_} ) } keys %$node } if ref $node eq 'HASH';
    return [ map { $strings->($_) } @$node ] if ref $node eq 'ARRAY';
    return ref $node ? $node : defined $node ? "$node" : undef;
  };
  my $key = $self->_json_string( $strings->($arguments) );
  undef $strings;
  return $key // '';
}

# The Langertha::Response of what plugin_after_llm_response got: the
# Response itself, or the tool loop's raw body read as the loop reads it.
# Reading it here must neither die nor warn twice, so both are contained.
sub _as_response {
  my ( $self, $data ) = @_;
  return $data if blessed($data) && $data->isa('Langertha::Response');
  return undef unless ref $data eq 'HASH';
  my $engine = $self->_host_engine;
  return undef unless blessed($engine) && $engine->can('tool_loop_response');
  local $@;
  local $SIG{__WARN__} = sub { };
  my $response = eval { $engine->tool_loop_response($data) };
  return blessed($response) && $response->isa('Langertha::Response') ? $response : undef;
}

# --- gen_ai.input.messages / gen_ai.output.messages (capture_content) ---

# The conversation as the conventions' ChatMessage list. The hooks get the
# messages in the engine's wire shape, so the common shapes are read: string
# or block content (OpenAI, Anthropic), Gemini parts, OpenAI/Ollama
# tool_calls and tool results. A block of any other kind is kept as a
# generic part.
sub _input_messages {
  my ( $self, $conversation ) = @_;
  my $safe = $self->_json_safe($conversation);
  return [] unless ref $safe eq 'ARRAY';
  return [ map { _chat_message($_) } @$safe ];
}

sub _chat_message {
  my ( $message ) = @_;
  return { role => 'user', parts => [ _text_part($message) ] } unless ref $message eq 'HASH';
  my $role = $message->{role} // 'user';
  $role = 'assistant' if $role eq 'model';
  $role = 'tool'      if $role eq 'function';
  if ( $role eq 'tool' && defined $message->{tool_call_id} ) {
    return { role => 'tool', parts => [ {
      type => 'tool_call_response', id => "$message->{tool_call_id}", response => $message->{content},
    } ] };
  }
  my @parts;
  push @parts, _content_parts( $message->{content} ) if defined $message->{content};
  push @parts, map { _gemini_part($_) } @{ $message->{parts} } if ref $message->{parts} eq 'ARRAY';
  for my $call ( ref $message->{tool_calls} eq 'ARRAY' ? @{ $message->{tool_calls} } : () ) {
    next unless ref $call eq 'HASH';
    my $function = ref $call->{function} eq 'HASH' ? $call->{function} : $call;
    push @parts, _tool_call_part( $call->{id}, $function->{name}, $function->{arguments} );
  }
  return { role => $role, parts => \@parts };
}

sub _text_part {
  my ( $text ) = @_;
  return { type => 'text', content => defined $text ? "$text" : '' };
}

sub _tool_call_part {
  my ( $id, $name, $arguments ) = @_;
  if ( defined $arguments && !ref $arguments ) {
    my $decoded = eval { JSON::MaybeXS->new( utf8 => 0 )->decode($arguments) };
    $arguments = $decoded if ref $decoded;
  }
  return {
    type      => 'tool_call',
    id        => defined $id && length $id ? "$id" : undef,
    name      => $name // '',
    arguments => $arguments,
  };
}

sub _generic_part {
  my ( $block ) = @_;
  return $block if ref $block eq 'HASH' && defined $block->{type} && !ref $block->{type};
  return { type => 'unknown', content => $block };
}

sub _content_parts {
  my ( $content ) = @_;
  return _text_part($content) unless ref $content;
  return _generic_part($content) unless ref $content eq 'ARRAY';
  my @parts;
  for my $block (@$content) {
    if ( !ref $block ) { push @parts, _text_part($block); next }
    my $type = ref $block eq 'HASH' ? $block->{type} // '' : '';
    if ( $type =~ /\A(?:input_|output_)?text\z/ && defined $block->{text} ) {
      push @parts, _text_part( $block->{text} );
    }
    elsif ( $type eq 'tool_use' ) {
      push @parts, _tool_call_part( @{$block}{qw( id name input )} );
    }
    elsif ( $type eq 'tool_result' ) {
      push @parts, { type => 'tool_call_response', id => $block->{tool_use_id}, response => $block->{content} };
    }
    else {
      push @parts, _generic_part($block);
    }
  }
  return @parts;
}

sub _gemini_part {
  my ( $part ) = @_;
  return _text_part($part) unless ref $part;
  return _generic_part($part) unless ref $part eq 'HASH';
  return _text_part( $part->{text} ) if defined $part->{text} && !$part->{thought};
  if ( ref $part->{functionCall} eq 'HASH' ) {
    my $call = $part->{functionCall};
    return _tool_call_part( @{$call}{qw( id name args )} );
  }
  if ( ref $part->{functionResponse} eq 'HASH' ) {
    my $result = $part->{functionResponse};
    return { type => 'tool_call_response', id => $result->{id}, response => $result->{response} };
  }
  return _generic_part($part);
}

# The conventions' FinishReason enum from a provider's finish reason.
my %FINISH = (
  stop => 'stop', end_turn => 'stop', stop_sequence => 'stop', STOP => 'stop',
  completed => 'stop', eos => 'stop',
  length => 'length', max_tokens => 'length', MAX_TOKENS => 'length',
  tool_calls => 'tool_call', tool_use => 'tool_call', function_call => 'tool_call',
  content_filter => 'content_filter', SAFETY => 'content_filter', refusal => 'content_filter',
  RECITATION => 'content_filter', PROHIBITED_CONTENT => 'content_filter', BLOCKLIST => 'content_filter',
  IMAGE_SAFETY => 'content_filter',
  error => 'error',
);

sub _output_messages {
  my ( $self, $data, $response ) = @_;
  my ( $text, @calls, $finish );
  if ($response) {
    $text   = $response->content;
    @calls  = $response->has_tool_calls ? @{ $response->tool_calls } : ();
    $finish = $response->finish_reason if $response->has_finish_reason;
  }
  elsif ( defined $data && !ref $data ) {
    $text = $data;
  }
  else {
    return undef;
  }
  my @parts;
  push @parts, _text_part($text) if defined $text && length $text;
  push @parts, map { _tool_call_part( $_->id, $_->name, $self->_json_safe( $_->arguments ) ) } @calls;
  my $reason = defined $finish ? $FINISH{$finish} // $FINISH{ lc $finish } : undef;
  $reason //= @calls ? 'tool_call' : 'stop';
  return [ { role => 'assistant', parts => \@parts, finish_reason => $reason } ];
}

# --- Flushing ---

sub _flush_args {
  my ( $self ) = @_;
  my @spans = @{ $self->_batch };
  return unless @spans;
  $self->_batch([]);
  my $size = $self->flush_batch_size;
  $size = 1 if $size < 1;
  my @chunks;
  push @chunks, [ splice @spans, 0, $size ] while @spans;
  return (
    chunks   => \@chunks,
    endpoint => $self->endpoint,
    headers  => $self->headers,
    otlp     => $self->_otlp,
    agent    => 'Langertha-Plugin-OTel/' . $VERSION,
    timeout  => $self->flush_timeout,
  );
}

sub _send_f {
  my ( $self, %args ) = @_;
  return $self->_send_chunks_f( %args, engine => scalar $self->_flush_engine );
}

# Sends the chunks one request after another; never fails. The transport is
# Role::Langfuse's: the host engine's async backend with the short timeout,
# else a dedicated LWP agent. A transport failure (timeout, refused) stops
# the flush: the remaining chunks would only wait out the same timeout.
async sub _send_chunks_f {
  my ( $self, %args ) = @_;
  my @chunks = @{ $args{chunks} };
  my @responses;
  while ( my $chunk = shift @chunks ) {
    my $body = eval { $args{otlp}->to_json($chunk) };
    unless ( defined $body ) {
      my $error = ( split /\n/, "$@" )[0] // 'unknown error';
      warn "OTLP trace export: could not encode " . scalar(@$chunk) . " span(s): $error\n";
      next;
    }
    require HTTP::Request;
    # The body is OTLP JSON, so the plugin owns Content-Type: a configured
    # one, in any casing, would otherwise be sent beside it.
    my %headers = %{ $args{headers} || {} };
    delete @headers{ grep { lc eq 'content-type' } keys %headers };
    my $request = HTTP::Request->new( POST => $args{endpoint},
      [ %headers, 'Content-Type' => 'application/json' ], $body );
    my $response = await Langertha::Role::Langfuse->_langfuse_send_f( $args{engine}, $request, %args );
    push @responses, $response;
    _check_export( $response, scalar @$chunk );
    if ( @chunks && ( $response->header('Client-Warning') // '' ) eq 'Internal response' ) {
      my $dropped = 0;
      $dropped += @$_ for @chunks;
      warn "OTLP trace export: endpoint unreachable, dropping $dropped more span(s)\n";
      last;
    }
  }
  return @responses;
}

# Warns about what did not arrive; never dies. A receiver that accepts part
# of a request answers 200 with partialSuccess.rejectedSpans.
sub _check_export {
  my ( $response, $count ) = @_;
  unless ( $response->is_success ) {
    warn "OTLP trace export failed: " . $response->status_line . " ($count span(s) lost)\n";
    return;
  }
  my $data = eval { JSON::MaybeXS->new( utf8 => 1 )->decode( $response->content ) };
  my $partial = ref $data eq 'HASH' && ref $data->{partialSuccess} eq 'HASH' ? $data->{partialSuccess} : {};
  my $rejected = $partial->{rejectedSpans} // 0;
  return unless $rejected && $rejected =~ /\A\d+\z/ && $rejected > 0;
  my $message = $partial->{errorMessage};
  warn sprintf "OTLP trace export: %d of %d span(s) rejected%s\n", $rejected, $count,
    defined $message && length $message ? " ($message)" : '';
  return;
}

sub flush {
  my ( $self ) = @_;
  return unless $self->enabled;
  $self->_await_pending_flushes;
  my %args = $self->_flush_args or return;
  my @responses = $self->_send_chunks_f(%args)->get;
  return $responses[-1];
}

=method flush

    $otel->flush;

Sends the recorded spans to L</endpoint> over a dedicated L<LWP::UserAgent>
with L</flush_timeout>, and clears the batch. Blocks until done; first it waits
for any L</auto_flush> request still in flight. Do not call it from inside an
event loop; use L</flush_f> there. Returns the L<HTTP::Response> of the last
request, or nothing when there was nothing to send.

It never dies. It warns when a request fails (its spans are lost, and after a
timeout or refused connection the rest of the flush is dropped too) and when
the receiver reports rejected spans (C<partialSuccess>).

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

    await $otel->flush_f;

Async L</flush>: waits for L</auto_flush> requests still in flight, then sends
through the host engine's async backend (L<Langertha::Role::AsyncHTTP>) with
L</flush_timeout> as each request's total timeout. Resolves to the
L<HTTP::Response> of each request and B<never fails>; problems are warned
about as in L</flush>. Without an engine on the host, or on the synchronous
fallback, it runs like L</flush>.

=cut

sub reset_trace {
  my ( $self ) = @_;
  $self->_trace_id(undef);
  $self->_llm_span(undef);
  $self->_parent_id(undef);
  $self->_op_start(undef);
  $self->_tool_starts({});
  $self->_tool_ids([]);
  return;
}

=method reset_trace

    $otel->reset_trace;

Starts a new trace with the next call. Call it between independent
conversations; spans not yet flushed are kept.

=cut

=seealso

=over

=item * L<Langertha::Trace::OTLP> - The payload builder and the C<gen_ai.*> mapping

=item * L<Langertha::Plugin::Langfuse> - Langfuse's own ingestion API instead of OTLP

=item * L<Langertha::Plugin> - Base class with all hook method signatures

=item * L<Langertha::Role::PluginHost> - Plugin system consumed by hosts

=item * L<https://github.com/open-telemetry/semantic-conventions/blob/v1.41.1/docs/gen-ai/gen-ai-spans.md> - GenAI spans, v1.41.1

=item * L<https://opentelemetry.io/docs/specs/otel/protocol/exporter/> - The C<OTEL_EXPORTER_OTLP_*> variables

=back

=cut

# --- Plugin hooks ---

async sub plugin_before_llm_call {
  my ( $self, $conversation, $iteration ) = @_;
  return $conversation unless $self->enabled;
  # A new turn: tool starts nobody finished belong to no call any more.
  $self->_tool_starts({});
  my %attr = $self->_request_attributes('chat');
  if ( $self->capture_content ) {
    my $messages = $self->_json_string( $self->_input_messages($conversation) );
    $attr{'gen_ai.input.messages'} = $messages if defined $messages;
  }
  # An open span is replaced: its call failed without an after-hook.
  $self->_llm_span({
    trace_id   => $self->_trace,
    span_id    => Langertha::Trace::OTLP->new_span_id,
    name       => _span_name( 'chat', \%attr ),
    kind       => 'client',
    start      => _now(),
    attributes => \%attr,
  });
  return $conversation;
}

async sub plugin_after_llm_response {
  my ( $self, $data, $iteration, $call ) = @_;
  return $data unless $self->enabled;
  my $span = $self->_llm_span or return $data;
  $self->_llm_span(undef);
  $span->{end} = _now();
  my $attr = $span->{attributes};
  $attr->{'gen_ai.request.stream'} = 1 if _streamed($call);

  my $response = $self->_as_response($data);
  %$attr = ( %$attr, Langertha::Trace::OTLP->response_attributes($response) ) if $response;

  if ( $self->capture_content ) {
    my $output = $self->_output_messages( $data, $response );
    my $text = $output ? $self->_json_string($output) : undef;
    $attr->{'gen_ai.output.messages'} = $text if defined $text;
  }

  # The calls the model asked for, so a tool span can name its call id.
  my @calls = $response && $response->has_tool_calls ? @{ $response->tool_calls } : ();
  $self->_tool_ids([ map {
    +{ name => $_->name, id => $_->id, arguments => $self->_arguments_key( $_->arguments ) }
  } @calls ]);

  $self->_push($span);
  $self->_parent_id( $span->{span_id} );
  $self->_auto_flush if $self->auto_flush;
  return $data;
}

async sub plugin_llm_call_failed {
  my ( $self, $error, $iteration, $call ) = @_;
  return unless $self->enabled;
  my $span = $self->_llm_span or return;
  $self->_llm_span(undef);
  $self->_tool_ids([]);
  $span->{end} = _now();
  my $attr = $span->{attributes};
  $attr->{'gen_ai.request.stream'} = 1 if _streamed($call);
  $attr->{'error.type'} = _error_type( $error, $call );
  # The message can quote the provider's answer, and with it the prompt.
  my $message = $self->capture_content ? _error_summary($error) : undef;
  $span->{status} = { code => 'error', defined $message ? ( message => $message ) : () };
  $self->_push($span);
  $self->_auto_flush if $self->auto_flush;
  return;
}

sub _streamed {
  my ( $call ) = @_;
  return ref $call eq 'HASH' && $call->{stream} ? 1 : 0;
}

# A provider error code is an identifier; anything else (a message, a
# number) is not taken as one.
my $ERROR_CODE = qr/\A[A-Za-z][A-Za-z0-9_.:\-]{0,99}\z/;

# error.type: the provider's own error code when its answer names one, else
# the exception class, else the HTTP status of an error answer, else _OTHER.
sub _error_type {
  my ( $error, $call ) = @_;
  my $response = ref $call eq 'HASH' ? $call->{http_response} : undef;
  undef $response unless blessed($response) && $response->isa('HTTP::Response');
  my $code = $response ? _provider_error_code($response) : undef;
  return $code if defined $code;
  return ref $error if blessed($error);
  return '' . $response->code if $response && !$response->is_success && $response->code;
  return '_OTHER';
}

# The code of an OpenAI-style ({error:{code,type}}), Anthropic-style
# ({type:"error",error:{type}}) or Google-style ({error:{code,status}}) error
# body. Only a small, uncompressed JSON body is read.
sub _provider_error_code {
  my ( $response ) = @_;
  return undef if $response->header('Content-Encoding');
  my $body = $response->content;
  return undef unless defined $body && length $body && length $body <= 65536;
  my $data = eval { JSON::MaybeXS->new( utf8 => 1 )->decode($body) };
  $data = $data->[0] if ref $data eq 'ARRAY';
  return undef unless ref $data eq 'HASH' && ref $data->{error} eq 'HASH';
  my $error = $data->{error};
  for my $key (qw( code status type )) {
    my $value = $error->{$key};
    return $value if defined $value && !ref $value && $value =~ $ERROR_CODE;
  }
  return undef;
}

sub _error_summary {
  my ( $error ) = @_;
  my $line = ( split /\n/, ( defined $error ? "$error" : '' ) )[0];
  return undef unless defined $line && length $line;
  return length $line > 1000 ? substr( $line, 0, 1000 ) . '...' : $line;
}

# With the host's call HashRef the start is kept by that HashRef; a host
# that passes none gets the start of the oldest open call of that name.
async sub plugin_before_tool_call {
  my ( $self, $name, $input, $call ) = @_;
  return ( $name, $input ) unless $self->enabled;
  if ( ref $call eq 'HASH' ) {
    $self->_call_starts->{$call} = _now();
  }
  elsif ( defined $name ) {
    push @{ $self->_tool_starts->{$name} }, _now();
  }
  return ( $name, $input );
}

async sub plugin_after_tool_call {
  my ( $self, $name, $input, $result, $call ) = @_;
  return $result unless $self->enabled;
  my $end = _now();
  my $by_call = ref $call eq 'HASH';
  my $start = $by_call ? delete $self->_call_starts->{$call}
    : defined $name    ? shift( @{ $self->_tool_starts->{$name} // [] } )
    :                    undef;
  $start //= $end;

  my %attr = (
    'gen_ai.operation.name' => 'execute_tool',
    'gen_ai.tool.name'      => $name,
    'gen_ai.tool.type'      => 'function',
    $self->_session_attributes,
  );
  if ($by_call) {
    my $id = $call->{id};
    $attr{'gen_ai.tool.call.id'} = "$id" if defined $id && !ref $id && length $id;
  }
  else {
    my $arguments = $self->_arguments_key($input);
    my $ids = $self->_tool_ids;
    for my $i ( 0 .. $#$ids ) {
      next unless defined $name && $ids->[$i]{name} eq $name && $ids->[$i]{arguments} eq $arguments;
      my ($match) = splice @$ids, $i, 1;
      $attr{'gen_ai.tool.call.id'} = $match->{id} if length $match->{id};
      last;
    }
  }
  if ( $self->capture_content ) {
    my $args_text   = $self->_json_string( $self->_json_safe($input) );
    my $result_text = $self->_json_string( $self->_json_safe($result) );
    $attr{'gen_ai.tool.call.arguments'} = $args_text   if defined $args_text;
    $attr{'gen_ai.tool.call.result'}    = $result_text if defined $result_text;
  }
  my $failed = ref $result eq 'HASH' && $result->{isError};
  $attr{'error.type'} = '_OTHER' if $failed;

  $self->_push({
    trace_id   => $self->_trace,
    span_id    => Langertha::Trace::OTLP->new_span_id,
    defined $self->_parent_id ? ( parent_span_id => $self->_parent_id ) : (),
    name       => defined $name ? "execute_tool $name" : 'execute_tool',
    kind       => 'internal',
    start      => $start,
    end        => $end,
    attributes => \%attr,
    $failed ? ( status => { code => 'error' } ) : (),
  });
  return $result;
}

async sub plugin_before_embedding {
  my ( $self, $text ) = @_;
  $self->_op_start( _now() ) if $self->enabled;
  return $text;
}

async sub plugin_after_embedding {
  my ( $self, $text, $vector, $call_result ) = @_;
  return $vector unless $self->enabled;
  my %attr = (
    $self->_request_attributes('embeddings'),
    Langertha::Trace::OTLP->call_result_attributes($call_result),
  );
  # A batch is an ArrayRef of vectors: the width of one.
  my $first = ref $vector eq 'ARRAY' ? $vector->[0] : undef;
  my $width = ref $first eq 'ARRAY' ? scalar @$first : ref $vector eq 'ARRAY' ? scalar @$vector : undef;
  $attr{'gen_ai.embeddings.dimension.count'} = $width if $width;
  $self->_push_operation( 'embeddings', \%attr );
  return $vector;
}

async sub plugin_before_image_gen {
  my ( $self, $prompt ) = @_;
  $self->_op_start( _now() ) if $self->enabled;
  return $prompt;
}

async sub plugin_after_image_gen {
  my ( $self, $prompt, $result, $call_result ) = @_;
  return $result unless $self->enabled;
  my %attr = (
    $self->_request_attributes('generate_content'),
    'gen_ai.output.type' => 'image',
    Langertha::Trace::OTLP->call_result_attributes($call_result),
  );
  if ( $self->capture_content && defined $prompt && !ref $prompt ) {
    my $messages = $self->_json_string([ { role => 'user', parts => [ _text_part($prompt) ] } ]);
    $attr{'gen_ai.input.messages'} = $messages if defined $messages;
  }
  $self->_push_operation( 'generate_content', \%attr );
  return $result;
}

sub _push_operation {
  my ( $self, $operation, $attr ) = @_;
  my $end = _now();
  my $start = $self->_op_start // $end;
  $self->_op_start(undef);
  $self->_push({
    trace_id   => $self->_trace,
    span_id    => Langertha::Trace::OTLP->new_span_id,
    name       => _span_name( $operation, $attr ),
    kind       => 'client',
    start      => $start,
    end        => $end,
    attributes => $attr,
  });
  $self->_auto_flush if $self->auto_flush;
  return;
}

# JSON-safe snapshots and the non-blocking auto_flush, shared with
# Plugin::Langfuse (k403).
with 'Langertha::Role::TracePlugin';

__PACKAGE__->meta->make_immutable;

1;
