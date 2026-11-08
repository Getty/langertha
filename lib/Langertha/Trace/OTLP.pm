package Langertha::Trace::OTLP;
# ABSTRACT: Build OTLP/HTTP (JSON) trace payloads with the OpenTelemetry GenAI semantic conventions
our $VERSION = '0.506';
use Moose;
use Carp qw( croak );
use JSON::MaybeXS ();
use Scalar::Util qw( blessed looks_like_number );
use mro;

=head1 SYNOPSIS

    use Langertha::Trace::OTLP;
    use Time::HiRes ();

    my $otlp = Langertha::Trace::OTLP->new( service_name => 'my-app' );

    my $trace_id = Langertha::Trace::OTLP->new_trace_id;
    my $start    = Time::HiRes::time();
    my $response = $engine->simple_chat('Hello');

    my $span = {
      trace_id   => $trace_id,
      span_id    => Langertha::Trace::OTLP->new_span_id,
      name       => 'chat ' . $engine->chat_model,
      kind       => 'client',
      start      => $start,
      end        => Time::HiRes::time(),
      attributes => {
        Langertha::Trace::OTLP->request_attributes( $engine ),
        Langertha::Trace::OTLP->response_attributes( $response ),
      },
    };

    my $body = $otlp->to_json( [ $span ] );   # POST to .../v1/traces

=head1 DESCRIPTION

A pure payload builder, no transport: it turns neutral span records into an
L<OTLP/HTTP JSON|https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding>
trace payload (C<resourceSpans> / C<scopeSpans> / C<spans>), ready to POST as
C<application/json> to any OTLP/HTTP traces receiver: an OpenTelemetry
Collector, Langfuse's OTLP endpoint, Grafana Tempo, Phoenix, OpenLIT and
others. L<Langertha::Plugin::OTel> builds on it; a program that sees LLM calls
without a Langertha host (a proxy, say) can use it directly. It is the trace
sibling of L<Langertha::Runtime::Metrics::OTLP>.

The class methods L</request_attributes>, L</response_attributes>,
L</usage_attributes> and L</call_result_attributes> map Langertha's objects to
C<gen_ai.*> attributes.

B<Semantic conventions version.> The attributes follow the OpenTelemetry
semantic conventions B<v1.41.1>, GenAI spans
(L<https://github.com/open-telemetry/semantic-conventions/blob/v1.41.1/docs/gen-ai/gen-ai-spans.md>).
The GenAI conventions are marked I<Development> there and still change between
releases, so the version is pinned and named in every payload as the scope's
C<schemaUrl> (C<https://opentelemetry.io/schemas/1.41.1>). v1.41.1 is the last
release that carries the GenAI conventions: v1.42.0 deprecated every
C<gen_ai.*> attribute in favour of a separate GenAI conventions project that
has no release yet. The deprecated C<gen_ai.system> is never emitted;
C<gen_ai.provider.name> replaces it.

=head2 Span records

A span record is a HashRef:

=over 4

=item * C<trace_id> - 32 hex characters (required)

=item * C<span_id> - 16 hex characters (required)

=item * C<parent_span_id> - 16 hex characters; leave it out for a root span

=item * C<name> - the span name (required)

=item * C<kind> - C<internal> (default), C<server>, C<client>, C<producer> or
C<consumer>

=item * C<start>, C<end> - epoch seconds, fractions allowed (as
L<Time::HiRes/time> gives them, kept to the microsecond); C<end>
defaults to C<start>

=item * C<status> - C<< { code => 'error', message => '...' } >> or
C<< { code => 'ok' } >>; leave it out for the default (unset) status

=item * C<attributes> - HashRef of attributes (see L</Attribute types>)

=item * C<events> - ArrayRef of C<< { name, time, attributes } >>

=back

Ids are written in lowercase; an id of the wrong length or with non-hex
characters croaks.

=head2 Attribute types

OTLP attributes are typed. The well-known attributes get the type the
conventions give them, whatever the Perl scalar looks like: token counts,
C<gen_ai.request.max_tokens>, C<gen_ai.request.seed>,
C<gen_ai.request.choice.count>, C<gen_ai.embeddings.dimension.count> and
C<server.port> are C<intValue>; C<gen_ai.request.temperature>, C<top_p>,
C<top_k>, C<frequency_penalty>, C<presence_penalty> and
C<gen_ai.response.time_to_first_chunk> are C<doubleValue>;
C<gen_ai.request.stream> is C<boolValue>. An integer attribute takes an
integral number in any spelling (C<12>, C<12.0>, C<1.2e1>) and sends it as a
decimal string, as OTLP/JSON writes 64-bit integers; a boolean attribute takes
a JSON boolean, C<true> / C<false> (any case), C<1> / C<0> (C<1.0>, C<0.0>,
...) or the empty string (Perl's false). A value that does not fit its type,
including an integer outside the 64-bit range (or, written as a float such as
C<1e20>, beyond the 53 bits a float holds exactly), is sent as a string rather
than dropped.

Any other attribute is a C<stringValue> (ids and model names stay strings even
when they look like numbers), except: a JSON boolean is a C<boolValue>; an
ArrayRef is an C<arrayValue> of strings; a HashRef with exactly one key such as
C<intValue> or C<doubleValue> is taken as an OTLP C<AnyValue> as it is (the
way to send a typed value under a key this module does not know; an
C<intValue> is written as a decimal string, or sent as a C<stringValue> when it
is no integer); any other
reference is sent as its JSON text. C<undef> values are left out.

=cut

use constant SEMCONV_VERSION => '1.41.1';
use constant SCHEMA_URL      => 'https://opentelemetry.io/schemas/1.41.1';

=method SEMCONV_VERSION

The pinned semantic conventions version, C<1.41.1>.

=method SCHEMA_URL

C<https://opentelemetry.io/schemas/1.41.1>, the scope's C<schemaUrl>.

=cut

my %INT_ATTR = map { $_ => 1 } qw(
  gen_ai.usage.input_tokens
  gen_ai.usage.output_tokens
  gen_ai.usage.cache_read.input_tokens
  gen_ai.usage.cache_creation.input_tokens
  gen_ai.usage.reasoning.output_tokens
  gen_ai.request.max_tokens
  gen_ai.request.seed
  gen_ai.request.choice.count
  gen_ai.embeddings.dimension.count
  server.port
);

my %DOUBLE_ATTR = map { $_ => 1 } qw(
  gen_ai.request.temperature
  gen_ai.request.top_p
  gen_ai.request.top_k
  gen_ai.request.frequency_penalty
  gen_ai.request.presence_penalty
  gen_ai.response.time_to_first_chunk
);

my %BOOL_ATTR = map { $_ => 1 } qw( gen_ai.request.stream );

my %ANY_VALUE = map { $_ => 1 } qw(
  stringValue intValue doubleValue boolValue arrayValue kvlistValue bytesValue
);

my %KIND = ( internal => 1, server => 2, client => 3, producer => 4, consumer => 5 );

my %STATUS = ( ok => 1, error => 2 );

# Engine class (the part after Langertha::Engine::) => gen_ai.provider.name.
# The well-known values of the conventions where one applies, else the
# provider's name in the same lowercase/underscore style.
my %PROVIDER = (
  OpenAI            => 'openai',
  OpenAIResponses   => 'openai',
  Anthropic         => 'anthropic',
  Gemini            => 'gcp.gemini',
  Mistral           => 'mistral_ai',
  Groq              => 'groq',
  DeepSeek          => 'deepseek',
  XAI               => 'x_ai',
  Perplexity        => 'perplexity',
  Ollama            => 'ollama',
  OllamaOpenAI      => 'ollama',
  Moonshot          => 'moonshot_ai',
  MoonshotAnthropic => 'moonshot_ai',
  MiniMax           => 'minimax',
  MiniMaxAnthropic  => 'minimax',
  AKI               => 'aki',
  AKIOpenAI         => 'aki',
  AKIAnthropic      => 'aki',
  OpenRouter        => 'openrouter',
  HuggingFace       => 'huggingface',
  Replicate         => 'replicate',
  vLLM              => 'vllm',
  VLLMHook          => 'vllm',
  SGLang            => 'sglang',
  LlamaCpp          => 'llama_cpp',
  LMStudio          => 'lm_studio',
  LMStudioOpenAI    => 'lm_studio',
  LMStudioAnthropic => 'lm_studio',
  NousResearch      => 'nous_research',
  TSystems          => 't_systems',
  Scaleway          => 'scaleway',
  Hetzner           => 'hetzner',
  Cerebras          => 'cerebras',
  Whisper           => 'whisper',
  Virtual           => 'langertha.virtual',
  Mock              => 'langertha.virtual',
);

has service_name => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_service_name',
);

=attr service_name

The C<service.name> resource attribute. Without it, a C<service.name> in
L</resource_attributes> is used, else C<unknown_service:perl>.

=cut

has resource_attributes => (
  is      => 'ro',
  isa     => 'HashRef',
  default => sub { {} },
);

=attr resource_attributes

HashRef of further resource attributes (C<deployment.environment.name>,
C<service.version>, ...), typed as described in L</Attribute types>.

=cut

has scope_name => (
  is      => 'ro',
  isa     => 'Str',
  default => 'langertha',
);

=attr scope_name

The instrumentation scope name. Default C<langertha>.

=cut

has scope_version => (
  is      => 'ro',
  isa     => 'Str',
  default => sub { $VERSION },
);

=attr scope_version

The instrumentation scope version. Default: this module's version.

=cut

has _json => (
  is      => 'ro',
  lazy    => 1,
  default => sub { JSON::MaybeXS->new( utf8 => 1, canonical => 1 ) },
);

my $JSON_TEXT = JSON::MaybeXS->new( utf8 => 0, canonical => 1, allow_nonref => 1,
  convert_blessed => 1, allow_blessed => 1 );

sub build_payload {
  my ( $self, $spans ) = @_;
  croak "build_payload() requires an ArrayRef of span records"
    unless ref $spans eq 'ARRAY';

  my %resource = %{ $self->resource_attributes };
  $resource{'service.name'} = $self->service_name if $self->has_service_name;
  $resource{'service.name'} //= 'unknown_service:perl';

  return {
    resourceSpans => [
      {
        resource   => { attributes => _attributes( \%resource ) },
        scopeSpans => [
          {
            scope     => { name => $self->scope_name, version => $self->scope_version },
            schemaUrl => SCHEMA_URL,
            spans     => [ map { _span($_) } @$spans ],
          },
        ],
      },
    ],
  };
}

=method build_payload

    my $payload = $otlp->build_payload( \@span_records );

The OTLP/HTTP JSON trace payload for the span records, as a HashRef: one
resource with this object's resource attributes, one scope
(L</scope_name>, L</scope_version>, L</SCHEMA_URL>) holding the spans.

=cut

sub to_json {
  my ( $self, $spans ) = @_;
  return $self->_json->encode( $self->build_payload($spans) );
}

=method to_json

    my $body = $otlp->to_json( \@span_records );

L</build_payload> as a UTF-8 encoded JSON string, the request body.

=cut

sub _span {
  my ($record) = @_;
  croak "span record must be a HashRef" unless ref $record eq 'HASH';
  my $kind = $KIND{ lc( $record->{kind} // 'internal' ) }
    // croak "unknown span kind '$record->{kind}'";
  my $start = $record->{start} // croak "span record needs a start time";
  my %span = (
    traceId           => _hex_id( $record->{trace_id}, 32, 'trace_id' ),
    spanId            => _hex_id( $record->{span_id}, 16, 'span_id' ),
    name              => $record->{name} // croak("span record needs a name"),
    kind              => $kind,
    startTimeUnixNano => _unix_nano($start),
    endTimeUnixNano   => _unix_nano( $record->{end} // $start ),
    attributes        => _attributes( $record->{attributes} || {} ),
  );
  $span{parentSpanId} = _hex_id( $record->{parent_span_id}, 16, 'parent_span_id' )
    if defined $record->{parent_span_id} && length $record->{parent_span_id};
  if ( ref $record->{status} eq 'HASH' && defined $record->{status}{code} ) {
    my $code = $STATUS{ lc $record->{status}{code} }
      // croak "unknown span status code '$record->{status}{code}'";
    $span{status} = {
      code => $code,
      defined $record->{status}{message} ? ( message => "$record->{status}{message}" ) : (),
    };
  }
  if ( ref $record->{events} eq 'ARRAY' && @{ $record->{events} } ) {
    $span{events} = [ map {
      +{
        name         => $_->{name} // croak("span event needs a name"),
        timeUnixNano => _unix_nano( $_->{time} // $start ),
        attributes   => _attributes( $_->{attributes} || {} ),
      }
    } @{ $record->{events} } ];
  }
  return \%span;
}

sub _hex_id {
  my ( $id, $length, $what ) = @_;
  croak "span record needs a $what" unless defined $id;
  croak "$what must be $length hex characters" unless $id =~ /\A[0-9a-fA-F]{$length}\z/;
  return lc $id;
}

# Epoch seconds (fractions allowed) as a decimal string of nanoseconds,
# without going through a float of 1e18. A float epoch carries about a
# microsecond, so the fraction is rounded to whole microseconds.
sub _unix_nano {
  my ($seconds) = @_;
  croak "span time '$seconds' is not epoch seconds" unless looks_like_number($seconds) && $seconds >= 0;
  my $whole = int $seconds;
  my $nanos = sprintf( '%.0f', ( $seconds - $whole ) * 1e6 ) * 1000;
  if ( $nanos >= 1e9 ) { $whole++; $nanos = 0 }
  return $whole ? sprintf( '%d%09d', $whole, $nanos ) : "$nanos";
}

sub _attributes {
  my ($attrs) = @_;
  my @list;
  for my $key ( sort keys %$attrs ) {
    my $value = _any_value( $key, $attrs->{$key} );
    push @list, { key => $key, value => $value } if $value;
  }
  return \@list;
}

sub _is_bool {
  my ($value) = @_;
  return blessed($value) && ( $value->isa('JSON::PP::Boolean') || JSON::MaybeXS::is_bool($value) );
}

# A boolean from a JSON boolean or a plain scalar that spells one, as 1 or 0;
# undef when the value is no boolean.
sub _bool {
  my ($value) = @_;
  return $value ? 1 : 0 if _is_bool($value);
  return undef if ref $value;
  return 1 if lc $value eq 'true';
  return 0 if lc $value eq 'false' || $value eq '';
  return undef unless looks_like_number($value);
  return 1 if $value == 1;
  return 0 if $value == 0;
  return undef;
}

# An integer as the decimal string OTLP/JSON wants for an int64, or undef
# when the value is no integer or does not fit. Digit strings are checked
# as text (no float on the way); other numbers only while a float holds the
# integer exactly (below 2**53).
sub _int_string {
  my ($value) = @_;
  return undef if !defined $value || ref $value;
  if ( $value =~ /\A([-+]?)0*(\d+)\z/ ) {
    my ( $sign, $digits ) = ( $1, $2 );
    my $max = $sign eq '-' ? '9223372036854775808' : '9223372036854775807';
    return undef if length $digits > 19 || ( length $digits == 19 && $digits gt $max );
    return ( $sign eq '-' && $digits ne '0' ? '-' : '' ) . $digits;
  }
  return undef unless looks_like_number($value);
  my $number = 0 + $value;
  return undef unless $number == $number && abs($number) < 2**53 && $number == int $number;
  return $number == 0 ? '0' : sprintf( '%.0f', $number );
}

sub _any_value {
  my ( $key, $value ) = @_;
  return undef unless defined $value;
  if ( ref $value eq 'HASH' && keys %$value == 1 && $ANY_VALUE{ ( keys %$value )[0] } ) {
    return $value unless exists $value->{intValue};
    my $int = _int_string( $value->{intValue} );
    return defined $int ? { intValue => $int }
      : defined $value->{intValue} ? { stringValue => "$value->{intValue}" } : undef;
  }
  if ( _is_bool($value) || ( $BOOL_ATTR{$key} && !ref $value ) ) {
    my $bool = _bool($value);
    return { boolValue => $bool ? JSON::MaybeXS::true() : JSON::MaybeXS::false() } if defined $bool;
  }
  if ( ref $value eq 'ARRAY' ) {
    return { arrayValue => { values => [
      map { _is_bool($_) ? { boolValue => $_ ? JSON::MaybeXS::true() : JSON::MaybeXS::false() }
          : { stringValue => ref $_ ? $JSON_TEXT->encode($_) : "$_" } }
      grep { defined } @$value
    ] } };
  }
  return { stringValue => $JSON_TEXT->encode($value) } if ref $value;
  if ( $INT_ATTR{$key} ) {
    my $int = _int_string($value);
    return { intValue => $int } if defined $int;
  }
  return { doubleValue => $value + 0 }
    if $DOUBLE_ATTR{$key} && looks_like_number($value);
  return { stringValue => "$value" };
}

# --- ids ---

# Ids come from /dev/urandom, read unbuffered: a forked child shares the
# handle but not a buffer, so preforked workers never repeat each other's ids.
# Without it, rand() is reseeded in every new process, since a child would
# otherwise continue its parent's sequence. $URANDOM is 0 once opening failed.
our $URANDOM;
my $rand_pid;

sub _random_bytes {
  my ($count) = @_;
  if ( !defined $URANDOM ) {
    my $fh;
    $URANDOM = open( $fh, '<:raw', '/dev/urandom' ) ? $fh : 0;
  }
  if ($URANDOM) {
    my $buffer;
    my $got = sysread $URANDOM, $buffer, $count;
    return $buffer if defined $got && $got == $count;
  }
  if ( !defined $rand_pid || $rand_pid != $$ ) {
    srand();
    $rand_pid = $$;
  }
  return pack 'C*', map { int rand 256 } 1 .. $count;
}

sub _random_hex {
  my ($bytes) = @_;
  my $hex;
  do { $hex = unpack 'H*', _random_bytes($bytes) } while $hex !~ /[^0]/;
  return $hex;
}

sub new_trace_id { _random_hex(16) }

sub new_span_id { _random_hex(8) }

=method new_trace_id

    my $trace_id = Langertha::Trace::OTLP->new_trace_id;

A random, non-zero trace id: 32 lowercase hex characters, from
F</dev/urandom> where there is one. Elsewhere it falls back to Perl's C<rand>,
reseeded in each new process so forked workers do not repeat each other's
ids; that fallback is not cryptographically strong, ids only need to be
unique.

=method new_span_id

    my $span_id = Langertha::Trace::OTLP->new_span_id;

A random, non-zero span id: 16 lowercase hex characters.

=cut

# --- gen_ai.* attribute mapping ---

sub provider_name {
  my ( $class, $engine ) = @_;
  my $engine_class = blessed($engine) // $engine;
  return '_OTHER' unless defined $engine_class && length $engine_class;
  for my $isa ( @{ mro::get_linear_isa($engine_class) } ) {
    next unless $isa =~ /\ALangertha::Engine::(\w+)\z/;
    return $PROVIDER{$1} if exists $PROVIDER{$1};
  }
  return '_OTHER';
}

=method provider_name

    my $name = Langertha::Trace::OTLP->provider_name($engine);   # or a class name

The C<gen_ai.provider.name> of a Langertha engine (object or class name):
C<openai>, C<anthropic>, C<gcp.gemini>, C<mistral_ai>, C<x_ai>, C<ollama>,
C<vllm>, ... from a fixed table of the Langertha engines. A subclass of an
engine gets its nearest ancestor's name; anything else gets C<_OTHER>.
Engines speaking another provider's wire keep their own provider: an
L<Langertha::Engine::OpenRouter> is C<openrouter>, not C<openai>.

=cut

sub request_attributes {
  my ( $class, $engine, %opts ) = @_;
  my $operation = $opts{operation} // 'chat';
  my $can = sub { blessed($engine) && $engine->can( $_[0] ) };
  my %attr = (
    'gen_ai.operation.name' => $operation,
    'gen_ai.provider.name'  => $opts{provider_name} // $class->provider_name($engine),
  );

  my $model = $opts{model};
  unless ( defined $model ) {
    my $method = $operation eq 'embeddings' ? 'embedding_model'
               : $operation eq 'generate_content' ? 'image_model'
               : 'chat_model';
    $model = eval { $engine->$method } if $can->($method);
  }
  $attr{'gen_ai.request.model'} = $model if defined $model && !ref $model;

  if ( $can->('url') ) {
    my $url = eval { $engine->url };
    if ( defined $url && !ref $url && length $url ) {
      require URI;
      my $uri = URI->new($url);
      if ( $uri->can('host') && length( $uri->host // '' ) ) {
        $attr{'server.address'} = $uri->host;
        $attr{'server.port'}    = $uri->port;
      }
    }
  }

  return %attr unless $operation eq 'chat';

  my $temperature = $opts{temperature};
  $temperature //= $engine->temperature
    if $can->('has_temperature') && $engine->has_temperature;
  $attr{'gen_ai.request.temperature'} = $temperature if defined $temperature;
  $attr{'gen_ai.request.max_tokens'} = $engine->response_size
    if $can->('has_response_size') && $engine->has_response_size;
  $attr{'gen_ai.request.seed'} = $engine->seed
    if $can->('has_seed') && $engine->has_seed && defined $engine->seed;
  $attr{'gen_ai.output.type'} = 'json'
    if $can->('has_response_format') && $engine->has_response_format;
  return %attr;
}

=method request_attributes

    my %attr = Langertha::Trace::OTLP->request_attributes( $engine, %opts );

The request side of a call to C<$engine>: C<gen_ai.operation.name>,
C<gen_ai.provider.name>, C<gen_ai.request.model>, C<server.address> and
C<server.port> (from the engine's C<url>), and for C<chat> the request
parameters set on the engine: C<gen_ai.request.temperature>,
C<gen_ai.request.max_tokens> (C<response_size>), C<gen_ai.request.seed>, and
C<gen_ai.output.type> C<json> when the engine has a C<response_format>.
Parameters the engine leaves at the provider's default are left out.

Options: C<operation> (C<chat> (default), C<embeddings> or
C<generate_content>; it picks C<chat_model>, C<embedding_model> or
C<image_model> as the request model), C<model> and C<temperature> (overrides,
such as a L<Langertha::Chat>'s), C<provider_name> (instead of
L</provider_name>).

=cut

sub usage_attributes {
  my ( $class, $usage ) = @_;
  return () unless blessed($usage) && $usage->isa('Langertha::Usage');
  my $cached = $usage->cached_tokens;
  my $write  = $usage->cache_write_tokens;
  # An unreported count is left out, never sent as 0. Without a reported input
  # the cache counts are not folded into one either: they are only part of
  # the prompt.
  my $input;
  if ( $usage->has_input_tokens ) {
    $input = $usage->input_tokens;
    my $includes = $usage->input_includes_cache;
    $input += ( $cached // 0 ) + ( $write // 0 ) if defined $includes && !$includes;
  }
  my $reasoning = $usage->reasoning_tokens;
  return (
    defined $input ? ( 'gen_ai.usage.input_tokens' => $input ) : (),
    $usage->has_output_tokens ? ( 'gen_ai.usage.output_tokens' => $usage->output_tokens ) : (),
    $cached    ? ( 'gen_ai.usage.cache_read.input_tokens'     => $cached )    : (),
    $write     ? ( 'gen_ai.usage.cache_creation.input_tokens' => $write )     : (),
    $reasoning ? ( 'gen_ai.usage.reasoning.output_tokens'     => $reasoning ) : (),
  );
}

=method usage_attributes

    my %attr = Langertha::Trace::OTLP->usage_attributes( $response->usage );

C<gen_ai.usage.input_tokens> and C<gen_ai.usage.output_tokens> of a
L<Langertha::Usage>, plus C<gen_ai.usage.cache_read.input_tokens>,
C<gen_ai.usage.cache_creation.input_tokens> and
C<gen_ai.usage.reasoning.output_tokens> when the provider reported a non-zero
count. Nothing for anything but a L<Langertha::Usage>.

The input and output counts are sent when the provider reported them
(L<Langertha::Usage/has_input_tokens>, L<Langertha::Usage/has_output_tokens>),
a reported C<0> included, and left out when it did not: an unreported count is
never sent as C<0>.

The conventions count cache reads and writes B<in>
C<gen_ai.usage.input_tokens>, while L<Langertha::Usage/input_tokens> keeps
the provider's own meaning. When the usage says its input excludes the cache
(C<input_includes_cache> false, as Anthropic reports it), the cache reads and
writes are added; when it says it includes them, or does not say (C<undef>,
most providers, which do not report a cache split), the input count is sent as
the provider gave it. Without a reported input count, nothing is sent for it,
not even the cache reads and writes as a stand-in: they are only part of the
prompt, so their sum would read as a too-small input count.

=cut

sub response_attributes {
  my ( $class, $response ) = @_;
  return () unless blessed($response) && $response->isa('Langertha::Response');
  my %attr;
  $attr{'gen_ai.response.id'}    = $response->id    if $response->has_id && defined $response->id;
  $attr{'gen_ai.response.model'} = $response->model if $response->has_model && defined $response->model;
  $attr{'gen_ai.response.finish_reasons'} = [ $response->finish_reason ]
    if $response->has_finish_reason && defined $response->finish_reason;
  $attr{'gen_ai.response.time_to_first_chunk'} = $response->ttft_seconds if $response->has_ttft;
  %attr = ( %attr, $class->usage_attributes( $response->usage ) ) if $response->has_usage;
  return %attr;
}

=method response_attributes

    my %attr = Langertha::Trace::OTLP->response_attributes($response);

The response side of a L<Langertha::Response>: C<gen_ai.response.id>,
C<gen_ai.response.model>, C<gen_ai.response.finish_reasons> (the provider's
own finish reason as the single element, unmapped),
C<gen_ai.response.time_to_first_chunk> when the response carries a time to
first token, and the L</usage_attributes>. Each only when the response has it.

=cut

sub call_result_attributes {
  my ( $class, $call_result ) = @_;
  return () unless blessed($call_result) && $call_result->isa('Langertha::CallResult');
  return (
    $call_result->has_model && defined $call_result->model
      ? ( 'gen_ai.response.model' => $call_result->model ) : (),
    $call_result->has_usage ? $class->usage_attributes( $call_result->usage ) : (),
  );
}

=method call_result_attributes

    my %attr = Langertha::Trace::OTLP->call_result_attributes($call_result);

C<gen_ai.response.model> and the L</usage_attributes> of the
L<Langertha::CallResult> an embedding or image generation returns from its
C<*_result> method.

=cut

=seealso

=over

=item * L<Langertha::Plugin::OTel> - The plugin that records Langertha calls with this builder

=item * L<Langertha::Runtime::Metrics::OTLP> - The OTLP metrics sibling

=item * L<https://github.com/open-telemetry/semantic-conventions/blob/v1.41.1/docs/gen-ai/gen-ai-spans.md> - GenAI spans, v1.41.1

=item * L<https://opentelemetry.io/docs/specs/otlp/> - OTLP specification

=back

=cut

__PACKAGE__->meta->make_immutable;

1;
