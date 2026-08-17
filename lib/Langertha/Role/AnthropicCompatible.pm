package Langertha::Role::AnthropicCompatible;
# ABSTRACT: Role for Anthropic-compatible API format
our $VERSION = '0.503';
use Moose::Role;
use Carp qw( croak );
use JSON::MaybeXS;
use Langertha::ToolChoice;
use Langertha::Tool;
use Langertha::Response;
use Langertha::ToolCall;

=head1 SYNOPSIS

    # This role is not used directly - it's composed by engines
    # that implement the Anthropic-compatible /v1/messages API format.

    package My::Engine;
    use Moose;

    extends 'Langertha::Engine::AnthropicBase';

    sub _build_api_key { $ENV{MY_API_KEY} || die "needs api_key" }
    sub default_model { 'my-model' }

    __PACKAGE__->meta->make_immutable;

=head1 DESCRIPTION

This role provides the Anthropic C</v1/messages> wire-envelope methods for
chat, streaming, tool calling, structured-output emulation, model listing,
and rate-limit parsing. Engines that speak the Anthropic-compatible API format
(Anthropic itself, MiniMax's legacy shim, Moonshot Kimi, LM Studio's
Anthropic-compatible endpoint) compose this role via
L<Langertha::Engine::AnthropicBase>, which supplies the C<url> / HTTP / JSON
infrastructure from L<Langertha::Engine::Remote>.

As with L<Langertha::Role::OpenAICompatible>, this role is only
self-contained in isolation: it assumes the composer brings the
L<Langertha::Engine::Remote> infrastructure (C<url>, C<generate_http_request>,
C<parse_response>, C<json>, C<user_agent>, C<chat_model>,
C<get_response_size>, C<has_temperature>, C<reasoning_kwargs_for>,
C<prompt_cache_kwargs_for>, C<tool_wire_format>, C<has_parallel_tool_use> /
C<parallel_tool_use>, C<has_response_format> / C<response_format>) — normally
provided by extending L<Langertha::Engine::Remote> plus the universal roles
composed in L<Langertha::Engine::AnthropicBase>.

The wire envelope mirrors L<Langertha::Role::OpenAICompatible>: this role owns
the Anthropic request/response/stream/auth/rate-limit envelope, and the base
class stays a thin composition shell.

=cut

sub _build_reasoning_wire_format { 'anthropic' }
sub _build_cache_wire_format { 'anthropic' }

sub default_response_size { 1024 }

sub content_format { 'anthropic' }

has api_key => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_api_key {
  my ( $self ) = @_;
  return croak "".(ref $self)." requires api_key to be set";
}

=attr api_key

Anthropic-compatible API key sent as C<x-api-key>. Subclasses typically
override C<_build_api_key> to read a provider-specific environment variable.

=cut

has api_version => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_api_version { '2023-06-01' }

=attr api_version

The Anthropic API version header sent with every request. Defaults to
C<2023-06-01>.

=cut

has effort => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_effort',
);

=attr effort

Back-compat alias of L<Langertha::Role::ReasoningEffort/reasoning_effort>.
Controls the depth of thinking for reasoning models. When set (and
C<reasoning_effort> is not), it seeds C<reasoning_effort>, which is serialized
via L<Langertha::Reasoning> to C<output_config.effort> plus
C<thinking: { type =E<gt> 'adaptive' }> (the current Messages-API shape) rather
than the legacy top-level C<effort> key.

    my $claude = Langertha::Engine::Anthropic->new(
        api_key => $ENV{ANTHROPIC_API_KEY},
        model   => 'claude-opus-4-8',
        effort  => 'high',   # same as reasoning_effort => 'high'
    );

=cut

has inference_geo => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_inference_geo',
);

=attr inference_geo

Controls data residency for inference. Values: C<us>, C<eu>. When set, passed
as the C<inference_geo> parameter to keep processing in the specified region.

    my $claude = Langertha::Engine::Anthropic->new(
        api_key       => $ENV{ANTHROPIC_API_KEY},
        inference_geo => 'eu',
    );

=cut

sub update_request {
  my ( $self, $request ) = @_;
  $request->header('x-api-key', $self->api_key);
  $request->header('content-type', 'application/json');
  $request->header('anthropic-version', $self->api_version);
}

=method update_request

    $self->update_request($http_request);

Adds the C<x-api-key>, C<content-type: application/json>, and
C<anthropic-version> headers to outgoing requests.

=cut

sub chat_request {
  my ( $self, $messages, %extra ) = @_;

  # Canonical per-request controls (chat_f, karr #46) beat the engine
  # attributes on a per-key basis; the rest of %extra passes straight through.
  my $controls = delete $extra{controls} // {};

  # Anthropic has no native response_format. Translate json_object /
  # json_schema response_format hashes into a synthesized tool + forced
  # named tool_choice; the response parser will pull the structured
  # output out of the resulting tool_use block.
  my $rf_routed = $self->_translate_response_format(\%extra, $controls);

  $self->_normalize_tool_params(\%extra, $controls);
  my @msgs;
  my $system = "";
  for my $message (@{$messages}) {
    if ($message->{role} eq 'system') {
      $system .= "\n\n" if length $system;
      $system .= $message->{content};
    } else {
      push @msgs, $message;
    }
  }
  if ($system and scalar @msgs == 0) {
    push @msgs, {
      role => 'user',
      content => $system,
    };
    $system = undef;
  }
  return $self->generate_http_request( POST => $self->url.'/v1/messages', sub { $self->chat_response(shift, $rf_routed) },
    model => $self->chat_model,
    messages => \@msgs,
    exists $controls->{max_tokens}
      ? ( max_tokens => $controls->{max_tokens} )
      : ( max_tokens => $self->get_response_size ), # must be always set
    exists $controls->{temperature}
      ? ( temperature => $controls->{temperature} )
      : ( $self->has_temperature ? ( temperature => $self->temperature ) : () ),
    $self->generation_kwargs_for(%$controls),
    $self->has_inference_geo ? ( inference_geo => $self->inference_geo ) : (),
    $system ? ( system => $system ) : (),
    %extra,
  );
}

=method chat_request

    my $request = $engine->chat_request($messages, %extra);

Generates an Anthropic-format message request (C<POST /v1/messages>).
Includes model, messages, max_tokens, temperature, reasoning-effort and
prompt-cache controls, and optional C<system>. Returns an HTTP request
object.

=cut

# Anthropic has no response_format; emulate via a synthetic tool plus
# a forced tool_choice. The response_call will detect the synthetic
# tool_use block and lift its input back into the response content.
my $SYNTH_RF_TOOL_NAME = '__langertha_response_format__';

sub _translate_response_format {
  my ( $self, $extra, $controls ) = @_;

  # A per-request response_format (chat_f, karr #46) beats the engine
  # attribute, and is removed from the extras either way: the Messages API
  # has no response_format field and answers 400 when one reaches the wire.
  my $rf = exists $controls->{response_format}
    ? delete $controls->{response_format}
    : exists $extra->{response_format}
      ? delete $extra->{response_format}
      : $self->has_response_format ? $self->response_format : undef;
  return unless ref($rf) eq 'HASH';
  my $type = $rf->{type} // '';

  my ( $name, $schema, $description );
  if ( $type eq 'json_schema' && ref( $rf->{json_schema} ) eq 'HASH' ) {
    my $js = $rf->{json_schema};
    $name        = $js->{name} // $SYNTH_RF_TOOL_NAME;
    $schema      = $js->{schema};
    $description = $js->{description};
  }
  elsif ( $type eq 'json_object' ) {
    $name   = $SYNTH_RF_TOOL_NAME;
    $schema = { type => 'object', additionalProperties => JSON->true };
  }
  else {
    return;
  }
  return unless ref($schema) eq 'HASH';

  my $tool = Langertha::Tool->new(
    name         => $name,
    input_schema => $schema,
    ( defined $description ? ( description => $description ) : () ),
  )->to_anthropic;

  $extra->{tools} ||= [];
  push @{ $extra->{tools} }, $tool;
  $extra->{tool_choice} = { type => 'tool', name => $name };
  return $name;
}

=method _translate_response_format

Internal: turns a C<response_format> hash into a synthesized tool plus a forced
named C<tool_choice>, returning the synthetic tool name. Returns C<undef> when
no usable structure is present.

=cut

# Normalize tool_choice (any accepted format -> Anthropic native) and fold
# parallel_tool_use into the tool_choice block as Anthropic expects. A
# per-request parallel_tool_use control (chat_f, karr #46) beats the engine
# attribute.
sub _normalize_tool_params {
  my ( $self, $extra, $controls ) = @_;

  if ( exists $extra->{tool_choice} && defined $extra->{tool_choice} ) {
    if ( my $tc = Langertha::ToolChoice->from_hash( $extra->{tool_choice} ) ) {
      $extra->{tool_choice} = $tc->to( $self->tool_wire_format );
    }
  }

  return unless exists $extra->{tools};

  my $ptu;
  if ( exists $controls->{parallel_tool_use} ) {
    $ptu = $controls->{parallel_tool_use};
  }
  elsif ( $self->can('has_parallel_tool_use') && $self->has_parallel_tool_use ) {
    $ptu = $self->parallel_tool_use;
  }
  return unless defined $ptu;

  my $tc = $extra->{tool_choice};
  $tc = { type => 'auto' } unless ref($tc) eq 'HASH';
  unless ( exists $tc->{disable_parallel_tool_use} ) {
    $tc->{disable_parallel_tool_use} = $ptu ? JSON->false : JSON->true;
  }
  $extra->{tool_choice} = $tc;
}

=method _normalize_tool_params

Internal: normalizes C<tool_choice> to Anthropic's native format and folds
C<parallel_tool_use> into the C<tool_choice> block as C<disable_parallel_tool_use>.

=cut

sub chat_response {
  my ( $self, $response, $rf_routed ) = @_;
  my $data = $self->parse_response($response);
  my @blocks = @{$data->{content}};
  my $text = join('', map { $_->{text} // '' } grep { $_->{type} eq 'text' } @blocks);
  my @thinking = map { $_->{thinking} // '' } grep { $_->{type} eq 'thinking' } @blocks;
  my $thinking = @thinking ? join("\n", @thinking) : undef;
  my @tcs = Langertha::ToolCall->extract( $self->tool_wire_format, $data );

  # If the caller asked for a response_format and we routed it through a
  # synthesized tool, lift the tool_use input back into the content as
  # JSON so callers can treat it like any other structured-output result.
  # chat_request passes the synthesized tool name for both the per-request
  # and the engine-attribute path; the attribute check stays as the
  # fallback for callers invoking chat_response directly.
  $rf_routed = $self->has_response_format unless defined $rf_routed;
  if ( $rf_routed && @tcs ) {
    $text = $self->json->encode( $tcs[0]->arguments );
  }
  return Langertha::Response->new(
    content       => $text,
    raw           => $data,
    $data->{id} ? ( id => $data->{id} ) : (),
    $data->{model} ? ( model => $data->{model} ) : (),
    defined $data->{stop_reason} ? ( finish_reason => $data->{stop_reason} ) : (),
    $data->{usage} ? ( usage => $data->{usage} ) : (),
    defined $thinking ? ( thinking => $thinking ) : (),
    @tcs ? ( tool_calls => [ @tcs ] ) : (),
  );
}

=method chat_response

    my $response = $role->chat_response($http_response, $rf_routed);

Parses an Anthropic-format message response into a L<Langertha::Response>
object. When C<$rf_routed> (a synthetic tool name, or truthy for the
attribute path) and tool calls are present, lifts the first tool_use
arguments back into C<content> as JSON.

=cut

sub stream_format { 'sse' }

=method stream_format

    my $format = $engine->stream_format;

Returns C<'sse'> (Server-Sent Events), the streaming format used by
Anthropic-compatible APIs.

=cut

sub chat_stream_request {
  my ( $self, $messages, %extra ) = @_;

  # Canonical per-request controls (chat_f, karr #46) beat the engine
  # attributes on a per-key basis; the rest of %extra passes straight through.
  my $controls = delete $extra{controls} // {};

  # Anthropic has no native response_format, and the streaming path has no
  # Response to lift a synthesized tool_use back into content from — the
  # chat_request rewrite (_translate_response_format) depends on
  # chat_response doing that lift. Rather than silently streaming
  # unstructured text (karr #52 Folge 1) or leaking response_format onto
  # the wire (Folge 2), consume the key and refuse loudly: structured
  # output on Anthropic-family engines is a non-streaming feature.
  my $rf = exists $controls->{response_format}
    ? delete $controls->{response_format}
    : exists $extra{response_format}
      ? delete $extra{response_format}
      : $self->has_response_format ? $self->response_format : undef;
  if ( defined $rf && ref($rf) eq 'HASH' ) {
    my $type = $rf->{type} // '';
    my $honored = $type eq 'json_object'
      || ( $type eq 'json_schema'
        && ref( $rf->{json_schema} ) eq 'HASH'
        && ref( $rf->{json_schema}{schema} ) eq 'HASH' );
    if ($honored) {
      croak "".(ref $self)." cannot stream response_format: Anthropic-family engines "
        . "route structured output through a synthesized tool whose tool_use input "
        . "is lifted into Response.content by chat_response, and the streaming path "
        . "has no Response to lift from. Use chat_f/chat_request for structured output.";
    }
  }

  $self->_normalize_tool_params(\%extra, $controls);
  my @msgs;
  my $system = "";
  for my $message (@{$messages}) {
    if ($message->{role} eq 'system') {
      $system .= "\n\n" if length $system;
      $system .= $message->{content};
    } else {
      push @msgs, $message;
    }
  }
  if ($system and scalar @msgs == 0) {
    push @msgs, {
      role => 'user',
      content => $system,
    };
    $system = undef;
  }
  return $self->generate_http_request( POST => $self->url.'/v1/messages', sub {},
    model => $self->chat_model,
    messages => \@msgs,
    exists $controls->{max_tokens}
      ? ( max_tokens => $controls->{max_tokens} )
      : ( max_tokens => $self->get_response_size ), # must be always set
    exists $controls->{temperature}
      ? ( temperature => $controls->{temperature} )
      : ( $self->has_temperature ? ( temperature => $self->temperature ) : () ),
    $self->generation_kwargs_for(%$controls),
    $self->has_inference_geo ? ( inference_geo => $self->inference_geo ) : (),
    $system ? ( system => $system ) : (),
    stream => JSON->true,
    %extra,
  );
}

=method chat_stream_request

    my $request = $engine->chat_stream_request($messages, %extra);

Generates an Anthropic-format streaming request (SSE, C<stream =E<gt> true>).
Returns an HTTP request object for use with streaming execution.

=cut

sub parse_stream_chunk {
  my ( $self, $data, $event ) = @_;

  require Langertha::Stream::Chunk;

  # Anthropic uses event types: content_block_delta, message_delta, message_stop
  my $type = $data->{type} // '';

  if ($type eq 'content_block_delta') {
    my $delta = $data->{delta} || {};
    return Langertha::Stream::Chunk->new(
      content => $delta->{text} // '',
      raw => $data,
      is_final => 0,
    );
  }

  if ($type eq 'message_delta') {
    my $delta = $data->{delta} || {};
    return Langertha::Stream::Chunk->new(
      content => '',
      raw => $data,
      is_final => 0,
      $delta->{stop_reason} ? (finish_reason => $delta->{stop_reason}) : (),
      $data->{usage} ? (usage => $data->{usage}) : (),
    );
  }

  if ($type eq 'message_stop') {
    return Langertha::Stream::Chunk->new(
      content => '',
      raw => $data,
      is_final => 1,
    );
  }

  # Other event types (message_start, content_block_start, etc.) - skip
  return undef;
}

=method parse_stream_chunk

    my $chunk = $engine->parse_stream_chunk($data, $event);

Parses a single SSE data payload from an Anthropic-format stream by event
type. Returns a L<Langertha::Stream::Chunk>, or C<undef> for event types that
carry no content.

=cut

# Dynamic model listing with cursor pagination
sub list_models_request {
  my ($self, %params) = @_;
  my $url = $self->url.'/v1/models';

  # Add pagination params if provided
  if (%params) {
    require URI;
    my $uri = URI->new($url);
    $uri->query_form(%params);
    $url = $uri->as_string;
  }

  return $self->generate_http_request(
    GET => $url,
    sub { $self->list_models_response(shift) },
  );
}

=method list_models_request

    my $request = $engine->list_models_request;
    my $request = $engine->list_models_request(after_id => $last_id);

Generates an HTTP GET request for the Anthropic C</v1/models> endpoint,
optionally with pagination params. Returns an HTTP request object.

=cut

sub list_models_response {
  my ($self, $response) = @_;
  my $data = $self->parse_response($response);
  return $data;
}

=method list_models_response

    my $data = $engine->list_models_response($http_response);

Parses the Anthropic C</v1/models> response. Returns the full response
hashref.

=cut

sub _fetch_all_models {
  my ($self) = @_;
  my @all_models;
  my $after_id;

  do {
    my $request = $self->list_models_request(
      $after_id ? (after_id => $after_id, limit => 100) : ()
    );
    my $response = $self->user_agent->request($request);
    my $data = $request->response_call->($response);

    push @all_models, @{$data->{data}};
    $after_id = $data->{has_more} ? $data->{last_id} : undef;
  } while ($after_id);

  return \@all_models;
}

sub list_models {
  my ($self, %opts) = @_;

  # Check cache unless force_refresh requested
  unless ($opts{force_refresh}) {
    my $cache = $self->_models_cache;
    if ($cache->{timestamp} && time - $cache->{timestamp} < $self->models_cache_ttl) {
      return $opts{full} ? $cache->{models} : $cache->{model_ids};
    }
  }

  # Fetch all pages from API
  my $models = $self->_fetch_all_models;

  # Extract IDs and update cache
  my @model_ids = map { $_->{id} } @$models;
  $self->_models_cache({
    timestamp => time,
    models => $models,
    model_ids => \@model_ids,
  });

  return $opts{full} ? $models : \@model_ids;
}

=method list_models

    my $model_ids = $engine->list_models;
    my $models    = $engine->list_models(full => 1);
    my $models    = $engine->list_models(force_refresh => 1);

Fetches available models from the Anthropic API using cursor pagination.
Returns an ArrayRef of model ID strings by default, or full model objects
when C<full => 1> is passed. Results are cached for C<models_cache_ttl>
seconds (default: 3600). Pass C<force_refresh => 1> to bypass the cache.

=cut

# Tool calling support (MCP) is the tag-driven default in Langertha::Role::Tools.
sub _build_tool_wire_format { 'anthropic' }

sub _parse_rate_limit_headers {
  my ( $self, $http_response ) = @_;
  my %raw;
  for my $name (qw(
    anthropic-ratelimit-requests-limit
    anthropic-ratelimit-requests-remaining
    anthropic-ratelimit-requests-reset
    anthropic-ratelimit-tokens-limit
    anthropic-ratelimit-tokens-remaining
    anthropic-ratelimit-tokens-reset
    anthropic-ratelimit-input-tokens-limit
    anthropic-ratelimit-input-tokens-remaining
    anthropic-ratelimit-input-tokens-reset
    anthropic-ratelimit-output-tokens-limit
    anthropic-ratelimit-output-tokens-remaining
    anthropic-ratelimit-output-tokens-reset
  )) {
    my $val = $http_response->header($name);
    $raw{$name} = $val if defined $val;
  }
  return undef unless %raw;
  require Langertha::RateLimit;
  return Langertha::RateLimit->new(
    ( defined $raw{'anthropic-ratelimit-requests-limit'}     ? ( requests_limit     => $raw{'anthropic-ratelimit-requests-limit'} + 0 )     : () ),
    ( defined $raw{'anthropic-ratelimit-requests-remaining'} ? ( requests_remaining => $raw{'anthropic-ratelimit-requests-remaining'} + 0 ) : () ),
    ( defined $raw{'anthropic-ratelimit-requests-reset'}     ? ( requests_reset     => $raw{'anthropic-ratelimit-requests-reset'} )         : () ),
    ( defined $raw{'anthropic-ratelimit-tokens-limit'}       ? ( tokens_limit       => $raw{'anthropic-ratelimit-tokens-limit'} + 0 )       : () ),
    ( defined $raw{'anthropic-ratelimit-tokens-remaining'}   ? ( tokens_remaining   => $raw{'anthropic-ratelimit-tokens-remaining'} + 0 )   : () ),
    ( defined $raw{'anthropic-ratelimit-tokens-reset'}       ? ( tokens_reset       => $raw{'anthropic-ratelimit-tokens-reset'} )           : () ),
    raw => \%raw,
  );
}

=method _parse_rate_limit_headers

Parses C<anthropic-ratelimit-*> headers from the HTTP response into a
L<Langertha::RateLimit> object. The C<raw> hash captures extras like
C<input-tokens-limit> and C<output-tokens-limit>.

=cut

=seealso

=over

=item * L<Langertha::Engine::AnthropicBase> - Composes this role as a thin shell

=item * L<Langertha::Role::OpenAICompatible> - The parallel OpenAI wire-envelope role

=item * L<https://status.anthropic.com/> - Anthropic service status

=item * L<https://docs.anthropic.com/> - Official Anthropic documentation

=item * L<Langertha::Role::Chat> - Chat interface methods

=item * L<Langertha::Role::Tools> - MCP tool calling interface

=item * L<Langertha::Role::Streaming> - Streaming support (SSE format)

=item * L<Langertha::Engine::Gemini> - Another non-OpenAI-compatible engine

=back

=cut

1;
