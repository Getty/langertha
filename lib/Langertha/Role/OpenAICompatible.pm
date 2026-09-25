package Langertha::Role::OpenAICompatible;
# ABSTRACT: Role for OpenAI-compatible API format
our $VERSION = '0.503';
use Moose::Role;
use File::ShareDir::ProjectDistDir qw( :all );
use Carp qw( croak carp );
use JSON::MaybeXS;
use Langertha::ToolChoice;
use Langertha::Response;
use Langertha::ToolCall;

=head1 SYNOPSIS

    # This role is not used directly - it's composed by engines
    # that implement the OpenAI-compatible API format.

    package My::Engine;
    use Moose;

    with map { 'Langertha::Role::'.$_ } qw(
        JSON HTTP OpenAICompatible OpenAPI Models Temperature
        ResponseSize SystemPrompt Streaming Chat Tools
    );

    sub _build_api_key { $ENV{MY_API_KEY} || die "needs api_key" }
    sub default_model { 'my-model' }

    __PACKAGE__->meta->make_immutable;

=head1 DESCRIPTION

This role provides the OpenAI API format methods for chat completions,
embeddings, transcription, streaming, and tool calling. Engines that
use the OpenAI-compatible API format (whether OpenAI itself, Ollama's
C</v1> endpoint, or other compatible providers) can compose this role
instead of inheriting from L<Langertha::Engine::OpenAI>.

The role provides default implementations for all OpenAI-format operations.
Engines can override individual methods to customize behavior (e.g.,
different operation IDs for Mistral, or disabling unsupported features).

B<Engines should also compose these roles:>

=over 4

=item * L<Langertha::Role::JSON> - JSON encoding/decoding

=item * L<Langertha::Role::HTTP> - HTTP request handling

=item * L<Langertha::Role::OpenAPI> - OpenAPI spec-driven request generation

=item * L<Langertha::Role::Models> - Model management

=back

B<Engines using this role:>

=over 4

=item * Cloud providers — L<Langertha::Engine::OpenAI>,
L<Langertha::Engine::DeepSeek>, L<Langertha::Engine::Groq>,
L<Langertha::Engine::Hetzner>, L<Langertha::Engine::MiniMax>,
L<Langertha::Engine::Mistral>, L<Langertha::Engine::Moonshot>,
L<Langertha::Engine::XAI>, L<Langertha::Engine::Cerebras>,
L<Langertha::Engine::NousResearch>, L<Langertha::Engine::OpenRouter>,
L<Langertha::Engine::Replicate>, L<Langertha::Engine::HuggingFace>,
L<Langertha::Engine::Perplexity>, L<Langertha::Engine::AKIOpenAI>,
L<Langertha::Engine::TSystems>, L<Langertha::Engine::Scaleway>

=item * Self-hosted — L<Langertha::Engine::OllamaOpenAI>,
L<Langertha::Engine::vLLM>, L<Langertha::Engine::SGLang>,
L<Langertha::Engine::LlamaCpp>, L<Langertha::Engine::LMStudioOpenAI>

=back

The base classes L<Langertha::Engine::OpenAIBase> and
L<Langertha::Engine::OpenAI> also compose this role (and so every engine
that extends them inherits it without listing it explicitly).

=cut

has api_key => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_api_key { undef }

=attr api_key

Optional API key for Bearer token authentication. Override
C<_build_api_key> in engines that require authentication (typically
from an environment variable). When C<undef>, no Authorization header
is sent.

=cut

sub update_request {
  my ( $self, $request ) = @_;
  my $key = $self->api_key;
  $request->header('Authorization', 'Bearer '.$key) if defined $key;
}

=method update_request

    $role->update_request($http_request);

Adds C<Authorization: Bearer {api_key}> header to outgoing requests
when an API key is configured. Skipped when C<api_key> is C<undef>
(e.g. for local servers like vLLM or llama.cpp).

=cut

sub openapi_file { yaml => dist_file('Langertha','openai.yaml') };

=method openapi_file

    my ($type, $path) = $role->openapi_file;

Returns the OpenAI OpenAPI spec file path used for request generation.
Override in an engine to use a provider-specific spec (e.g., Mistral).

=cut

sub default_embedding_model { 'text-embedding-3-large' }
sub default_transcription_model { 'whisper-1' }
sub default_image_model { 'gpt-image-1' }

# Dynamic model listing

sub list_models_path { '/models' }

=method list_models_path

    my $path = $engine->list_models_path;

Returns the path appended to C<url> for the models endpoint.
Default: C</models>. Override in engines whose API spec uses a
different path (e.g. Mistral uses C</v1/models> because its base URL
does not include C</v1>).

=cut

sub list_models_request {
  my ($self, %params) = @_;
  my $url = $self->url.$self->list_models_path;
  if ($params{after}) {
    $url .= '?after='.$params{after};
  }
  return $self->generate_http_request(
    GET => $url,
    sub { $self->list_models_response(shift) },
  );
}

=method list_models_request

    my $request = $engine->list_models_request;
    my $request = $engine->list_models_request(after => $last_id);

Generates an HTTP GET request for the models endpoint using
C<list_models_path>. Pass C<after> for cursor-based pagination.
Returns an HTTP request object.

=cut

sub list_models_response {
  my ($self, $response) = @_;
  my $data = $self->parse_response($response);
  return $data;
}

=method list_models_response

    my $data = $engine->list_models_response($http_response);

Parses the C</v1/models> response. Returns the full response hashref
including C<data>, C<has_more>, and C<last_id> for pagination.

=cut

sub list_models {
  my ($self, %opts) = @_;

  # Guard: if supported_operations excludes listModels, fall back to current model
  unless ($self->can_operation('listModels')) {
    return [$self->model];
  }

  # Check cache unless force_refresh requested
  unless ($opts{force_refresh}) {
    my $cache = $self->_models_cache;
    if ($cache->{timestamp} && time - $cache->{timestamp} < $self->models_cache_ttl) {
      return $opts{full} ? $cache->{models} : $cache->{model_ids};
    }
  }

  # Fetch all pages
  my @all_models;
  my $after;
  for my $page (1..100) {
    my $request = $self->list_models_request($after ? (after => $after) : ());
    my $response = $self->user_agent->request($request);
    my $data = $request->response_call->($response);
    my $models = ref $data eq 'HASH' ? ($data->{data} // []) : $data;
    push @all_models, @$models;
    last unless ref $data eq 'HASH' && $data->{has_more} && $data->{last_id};
    $after = $data->{last_id};
  }

  # Extract IDs and update cache
  my @model_ids = map { $_->{id} } @all_models;
  $self->_models_cache({
    timestamp => time,
    models => \@all_models,
    model_ids => \@model_ids,
  });

  return $opts{full} ? \@all_models : \@model_ids;
}

=method list_models

    my $model_ids = $engine->list_models;
    # Returns: ['gpt-4o', 'gpt-4o-mini', ...]

    my $models = $engine->list_models(full => 1);
    # Returns: [{id => 'gpt-4o', created => ..., ...}, ...]

    my $fresh = $engine->list_models(force_refresh => 1);

Fetches available models from the C</v1/models> endpoint with caching.
Automatically paginates through all pages using cursor-based pagination
(C<has_more> / C<after>). By default returns an ArrayRef of model ID
strings. Pass C<full =E<gt> 1> for full model objects. Results are cached
for C<models_cache_ttl> seconds (default: 3600). Pass C<force_refresh =E<gt> 1>
to bypass the cache.

=cut

# Embedding

sub embedding_operation_id { 'createEmbedding' }

sub embedding_request {
  my ( $self, $input, %extra ) = @_;
  return $self->generate_request( $self->embedding_operation_id, sub { $self->embedding_response(shift) },
    defined $self->embedding_model ? ( model => $self->embedding_model ) : (),
    input => $input,
    %extra,
  );
}

=method embedding_request

    my $request = $engine->embedding_request($input, %extra);

Generates an OpenAI-format embedding request for the given C<$input>
string. Uses C<embedding_model> (default: C<text-embedding-3-large>).
Returns an HTTP request object.

=cut

sub embedding_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  # tracing
  # A malformed/error payload that still parses as a 200 JSON body can lack the
  # `data` array; croak with a readable message instead of a raw deref crash on
  # @{undef} ("Can't use an undefined value as an ARRAY reference"). Embeddings
  # must return a vector, so there is no graceful-empty fallback here. -- karr k171
  unless ( ref $data->{data} eq 'ARRAY' ) {
    my $err = ref $data eq 'HASH' && $data->{error}
      ? ( ref $data->{error} eq 'HASH' ? $data->{error}{message} : $data->{error} )
      : undef;
    croak "".(ref $self)." embedding response missing 'data' array"
      . ( defined $err ? " (error: $err)" : "" );
  }
  my @objects = @{$data->{data}};
  return $objects[0]->{embedding};
}

=method embedding_response

    my $vector = $engine->embedding_response($http_response);

Parses an OpenAI-format embedding response. Returns an ArrayRef of
floats representing the embedding vector.

=cut

# Chat

sub chat_operation_id { 'createChatCompletion' }

# The completion-length body key is engine-overridable. OpenAI's gpt-5.x line
# only accepts max_completion_tokens (max_tokens is an HTTP 400 on those
# models), so Langertha::Engine::OpenAI overrides this for the gpt-5* family;
# every other OpenAI-compatible engine keeps max_tokens.
sub _max_tokens_key { 'max_tokens' }

# OpenAI reasoning models (gpt-5.x / gpt-6 / o-series) 400 on a non-default
# temperature whenever reasoning is active -- only the wire default (1) is
# accepted (karr k155, live-verified 2026-09-17 against /v1/chat/completions).
# This gate mirrors AnthropicCompatible::_temperature_kwargs (the
# supports('temperature') check + control-beats-attribute resolution) and adds
# the OpenAI EFFORT-AWARE drop. The per-model, resolved-effort predicate lives on
# the engine (Engine::OpenAI::_temperature_rejected_by_reasoning, inherited by
# OpenAIResponses); every other OpenAI-compatible engine never defines it, so the
# can() guard leaves their temperature untouched. The drop fires only for a
# non-default value under active reasoning: temperature=1 passes through silently
# (dropping the wire default would be a pure-noise warning), and a caller who
# disables reasoning (reasoning_effort => 'none', where the model accepts it)
# keeps its temperature.
#
# A model that does not take temperature at all (supports('temperature') false:
# every current Kimi id fixes it server-side, karr k214) never gets the field,
# not even 1. A caller-set non-default value is dropped with a carp rather than
# silently (ADR 0025 k214 Update); 1 is dropped quietly.
sub _temperature_kwargs {
  my ( $self, $controls ) = @_;
  my $temp = exists $controls->{temperature} ? $controls->{temperature}
           : $self->can('has_temperature') && $self->has_temperature ? $self->temperature
           :                                    undef;
  return () unless defined $temp;
  unless ( $self->supports('temperature') ) {
    carp "".( ref $self ).": dropping temperature=$temp -- model '"
      . ( $self->can('chat_model') ? $self->chat_model // '' : '' )
      . "' does not take a temperature (rejected or fixed server-side); "
      . "unset temperature to silence this"
      if $temp != 1;
    return ();
  }
  if ( $temp != 1
    && $self->can('_temperature_rejected_by_reasoning')
    && $self->_temperature_rejected_by_reasoning($controls) ) {
    carp "".( ref $self ).": dropping temperature=$temp -- this reasoning model "
      . "rejects a non-default temperature while reasoning is active (only the "
      . "wire default 1 is accepted); pass reasoning_effort => 'none' to keep it";
    return ();
  }
  return ( temperature => $temp );
}

# Normalize tool_choice to OpenAI native format (accepts Anthropic-style,
# OpenAI-style, string shorthands and a Langertha::ToolChoice object), in place,
# for both request builders (the streaming one too, karr k235). The wire is
# always OpenAI-shaped here (see chat_response), so pin to 'openai' rather than
# $self->tool_wire_format (hermes engines / Perplexity).
sub _openai_tool_choice_kwarg {
  my ( $self, $extra ) = @_;
  return unless exists $extra->{tool_choice} && defined $extra->{tool_choice};
  if ( my $tc = Langertha::ToolChoice->from_hash( $extra->{tool_choice} ) ) {
    $extra->{tool_choice} = $tc->to('openai');
  }
  return;
}

# parallel_tool_use -> OpenAI's parallel_tool_calls (only when tools present),
# in place, for both request builders (the streaming one too, karr k240). A
# per-request control beats the engine attribute; an explicit
# parallel_tool_calls kwarg wins over both.
sub _openai_parallel_tool_calls_kwarg {
  my ( $self, $extra, $controls ) = @_;
  return unless exists $extra->{tools} && !exists $extra->{parallel_tool_calls};
  my $ptu;
  if ( exists $controls->{parallel_tool_use} ) {
    $ptu = $controls->{parallel_tool_use};
  }
  elsif ( $self->can('has_parallel_tool_use') && $self->has_parallel_tool_use ) {
    $ptu = $self->parallel_tool_use;
  }
  $extra->{parallel_tool_calls} = $ptu ? JSON->true : JSON->false if defined $ptu;
  return;
}

sub chat_request {
  my ( $self, $messages, %extra ) = @_;

  # Canonical per-request controls (chat_f, karr #46) beat the engine
  # attributes on a per-key basis; the rest of %extra passes straight through.
  my $controls = delete $extra{controls} // {};

  $self->_openai_tool_choice_kwarg(\%extra);
  $self->_openai_parallel_tool_calls_kwarg(\%extra, $controls);

  return $self->generate_request( $self->chat_operation_id, sub { $self->chat_response(shift) },
    defined $self->chat_model ? ( model => $self->chat_model ) : (),
    messages => $messages,
    exists $controls->{max_tokens}
      ? ( $self->_max_tokens_key => $controls->{max_tokens} )
      : ( $self->get_response_size ? ( $self->_max_tokens_key => $self->get_response_size ) : () ),
    exists $controls->{response_format}
      ? ( response_format => $controls->{response_format} )
      : ( ($self->can('has_response_format') && $self->has_response_format) ? ( response_format => $self->response_format ) : () ),
    $self->_temperature_kwargs($controls),
    exists $controls->{seed} ? ( seed => $controls->{seed} ) : (),
    $self->generation_kwargs_for(%$controls),
    ( $self->can('knobs_kwargs_for') ? $self->knobs_kwargs_for(%$controls) : () ),
    stream => JSON->false,
    %extra,
  );
}

=method chat_request

    my $request = $engine->chat_request($messages, %extra);

Generates an OpenAI-format chat completion request. Includes model,
messages, max_tokens, temperature, response_format (if set), and
C<stream =E<gt> false>. Returns an HTTP request object.

=cut

sub chat_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  my $choice = $data->{choices}[0];
  my $msg = $choice->{message} || {};
  # The OpenAI-compatible response envelope is always OpenAI-shaped, even for
  # engines whose tool_wire_format is 'hermes' (their calls ride in the message
  # text, parsed elsewhere).
  # Pin the structured extractor to 'openai' rather than $self->tool_wire_format.
  my @tcs = Langertha::ToolCall->extract( 'openai', $data );
  # Chain-of-thought reaches the OpenAI-compatible message under two spellings:
  # the DeepSeek/SGLang/Moonshot/xAI `reasoning_content`, and the bare
  # `reasoning` that vLLM (renamed from reasoning_content), Groq, Cerebras,
  # OpenRouter and AKI.IO send. Read the canonical spelling first, then fall
  # back to `reasoning` -- guarded !ref so OpenRouter's structured
  # `reasoning_details` ARRAY (or any non-string shape) never lands in the Str
  # thinking attribute. The precedence tests `length`, not `defined`: a server
  # that keeps `reasoning_content` as an empty back-compat stub beside a filled
  # `reasoning` must not mask it -- the exact failure mode the vLLM migration
  # note warns about. -- karr k127, k129, k79
  my $thinking =
      length( $msg->{reasoning_content} // '' ) ? $msg->{reasoning_content}
    : ( defined $msg->{reasoning} && !ref $msg->{reasoning} ) ? $msg->{reasoning}
    : undef;
  return Langertha::Response->new(
    content       => $msg->{content} // '',
    raw           => $data,
    $data->{id} ? ( id => $data->{id} ) : (),
    $data->{model} ? ( model => $data->{model} ) : (),
    defined $choice->{finish_reason} ? ( finish_reason => $choice->{finish_reason} ) : (),
    $data->{usage} ? ( usage => $data->{usage} ) : (),
    ( $data->{usage} && $data->{usage}{prompt_tokens_details}
      && defined $data->{usage}{prompt_tokens_details}{cached_tokens}
      ? ( cached_tokens => $data->{usage}{prompt_tokens_details}{cached_tokens} ) : () ),
    $data->{created} ? ( created => $data->{created} ) : (),
    defined $thinking ? ( thinking => $thinking ) : (),
    @tcs ? ( tool_calls => [ @tcs ] ) : (),
  );
}

=method chat_response

    my $response = $engine->chat_response($http_response);

Parses an OpenAI-format chat completion response. Returns a
L<Langertha::Response> object with C<content>, C<model>, C<finish_reason>,
C<usage>, C<created>, and C<raw>.

=cut

# Transcription

sub transcription_operation_id { 'createTranscription' }

sub transcription_request {
  my ( $self, $file, %extra ) = @_;
  return $self->generate_request( $self->transcription_operation_id, sub { $self->transcription_response(shift) },
    file => [ $file ],
    $self->transcription_model ? ( model => $self->transcription_model ) : (),
    %extra,
  );
}

=method transcription_request

    my $request = $engine->transcription_request($file_path, %extra);

Generates an OpenAI-format transcription request for the given audio file.
Uses C<transcription_model> (default: C<whisper-1>). Returns an HTTP
request object.

=cut

sub transcription_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  return $data->{text};
}

=method transcription_response

    my $text = $engine->transcription_response($http_response);

Parses an OpenAI-format transcription response. Returns the transcribed
text as a string.

=cut

# Streaming

sub stream_format { 'sse' }

=method stream_format

    my $format = $engine->stream_format;

Returns C<'sse'> (Server-Sent Events), indicating the streaming format
used by OpenAI-compatible APIs. Used by L<Langertha::Role::Chat> to
select the correct stream parser.

=cut

sub chat_stream_request {
  my ( $self, $messages, %extra ) = @_;

  # Same canonical-control consumption as chat_request (karr #46).
  my $controls = delete $extra{controls} // {};

  # Same tool_choice normalization and parallel_tool_calls placement as
  # chat_request (karr k235, k240).
  $self->_openai_tool_choice_kwarg(\%extra);
  $self->_openai_parallel_tool_calls_kwarg(\%extra, $controls);

  return $self->generate_request( $self->chat_operation_id, sub {},
    defined $self->chat_model ? ( model => $self->chat_model ) : (),
    messages => $messages,
    exists $controls->{max_tokens}
      ? ( $self->_max_tokens_key => $controls->{max_tokens} )
      : ( $self->get_response_size ? ( $self->_max_tokens_key => $self->get_response_size ) : () ),
    exists $controls->{response_format}
      ? ( response_format => $controls->{response_format} )
      : ( ($self->can('has_response_format') && $self->has_response_format) ? ( response_format => $self->response_format ) : () ),
    $self->_temperature_kwargs($controls),
    exists $controls->{seed} ? ( seed => $controls->{seed} ) : (),
    $self->generation_kwargs_for(%$controls),
    ( $self->can('knobs_kwargs_for') ? $self->knobs_kwargs_for(%$controls) : () ),
    stream => JSON->true,
    %extra,
  );
}

=method chat_stream_request

    my $request = $engine->chat_stream_request($messages, %extra);

Generates an OpenAI-format streaming chat request (C<stream =E<gt> true>).
Returns an HTTP request object for use with streaming execution.

=cut

sub parse_stream_chunk {
  my ( $self, $data, $event, $state ) = @_;

  return undef unless $data && $data->{choices};

  my $choice = $data->{choices}[0];
  return undef unless $choice;

  my $content = $choice->{delta}{content} // '';
  my $finish_reason = $choice->{finish_reason};

  # A streamed tool call arrives as delta.tool_calls fragments keyed by
  # `index`: the first carries id, type and function.name, the rest append to
  # function.arguments, and fragments of parallel calls interleave. Assemble
  # them per index in this stream's state and deliver the finished calls on the
  # chunk that carries finish_reason -- read by the same
  # ToolCall->extract('openai', ...) chat_response uses, so a streamed and a
  # non-streamed reply of one response yield the same calls. The calls leave the
  # state as they are delivered, so none arrives twice. A fragment without
  # `index` (servers that stream whole calls) is keyed by its id, and only by
  # its position when it has neither; an empty-string finish_reason is no
  # finish and flushes nothing. A stream that ends without a finish_reason is
  # reported by _finish_stream_state. -- karr k221
  $state //= $self->_stream_parse_state;
  my $pending = $state->{openai_tool_calls} //= {};
  my $order   = $state->{openai_tool_order} //= [];
  my $delta_calls = ref $choice->{delta} eq 'HASH' ? $choice->{delta}{tool_calls} : undef;
  if ( ref $delta_calls eq 'ARRAY' ) {
    for my $pos ( 0 .. $#$delta_calls ) {
      my $fragment = $delta_calls->[$pos];
      next unless ref $fragment eq 'HASH';
      my $key = defined $fragment->{index}     ? "index:$fragment->{index}"
              : length( $fragment->{id} // '' ) ? "id:$fragment->{id}"
              :                                   "pos:$pos";
      my $call = $pending->{$key} //= do {
        push @$order, $key;
        { type => 'function', function => { arguments => '' } };
      };
      $call->{id} = $fragment->{id} if !length( $call->{id} // '' ) && length( $fragment->{id} // '' );
      my $fn = ref $fragment->{function} eq 'HASH' ? $fragment->{function} : {};
      $call->{function}{name} = $fn->{name}
        if !length( $call->{function}{name} // '' ) && length( $fn->{name} // '' );
      if ( ref $fn->{arguments} ) { $call->{function}{arguments} = $fn->{arguments} }
      elsif ( defined $fn->{arguments} ) { $call->{function}{arguments} .= $fn->{arguments} }
    }
  }
  my @tool_calls;
  if ( length( $finish_reason // '' ) && @$order ) {
    my @calls = map { $pending->{$_} } @$order;
    %$pending = ();
    @$order   = ();
    @tool_calls = Langertha::ToolCall->extract( 'openai',
      { choices => [ { message => { tool_calls => \@calls } } ] } );
  }

  # Streamed chain-of-thought reaches the delta under the same two spellings the
  # non-streaming chat_response reads: the DeepSeek/SGLang/Moonshot/xAI
  # `reasoning_content`, and the bare `reasoning` that vLLM (renamed from
  # reasoning_content), Cerebras and AKI.IO send. Read the canonical spelling
  # first, then fall back to `reasoning` -- guarded !ref so a non-string shape
  # (e.g. OpenRouter's `reasoning_details` ARRAY, which the docs put on the
  # delta) never lands in the Str thinking attribute. As in chat_response the
  # precedence tests `length`, not `defined`, so an empty back-compat
  # `reasoning_content` stub cannot mask a filled `reasoning`. -- karr k129, k79
  my $delta = $choice->{delta} || {};
  my $thinking =
      length( $delta->{reasoning_content} // '' ) ? $delta->{reasoning_content}
    : ( defined $delta->{reasoning} && !ref $delta->{reasoning} ) ? $delta->{reasoning}
    : undef;

  require Langertha::Stream::Chunk;
  return Langertha::Stream::Chunk->new(
    content => $content,
    raw => $data,
    is_final => defined $finish_reason,
    defined $finish_reason ? (finish_reason => $finish_reason) : (),
    $data->{model} ? (model => $data->{model}) : (),
    $data->{usage} ? (usage => $data->{usage}) : (),
    ( $data->{usage} && $data->{usage}{prompt_tokens_details}
      && defined $data->{usage}{prompt_tokens_details}{cached_tokens}
      ? ( cached_tokens => $data->{usage}{prompt_tokens_details}{cached_tokens} ) : () ),
    defined $thinking ? ( thinking => $thinking ) : (),
    @tool_calls ? ( tool_calls => \@tool_calls ) : (),
  );
}

=method parse_stream_chunk

    my $chunk = $engine->parse_stream_chunk($data, $event, \%state);

Parses a single SSE data payload from an OpenAI-format stream. Returns
a L<Langertha::Stream::Chunk> with C<content>, C<is_final>, C<finish_reason>,
C<model>, C<usage>, C<cached_tokens> (lifted from
C<usage.prompt_tokens_details.cached_tokens> when present), and C<thinking>
(the streamed C<delta.reasoning_content> / bare C<delta.reasoning>, guarded
C<!ref>). Returns C<undef> only when the payload carries no C<choices>.

C<delta.tool_calls> fragments are assembled per C<index> (a fragment without
C<index> by its C<id>, and by its position only when it has neither) in
C<\%state>, and the finished calls land as L<Langertha::ToolCall> objects, in
stream order, on the chunk that carries a non-empty C<finish_reason>, read by the
same L<Langertha::ToolCall/extract> as L</chat_response>. Collect them with
L<Langertha::Role::Chat/aggregate_tool_calls>. C<finish_reason> is passed
through as the provider sent it, as on the non-streaming path. A stream that
ends without one drops its pending calls with a C<carp> (see
L</_finish_stream_state>).

C<\%state> is one HashRef per stream. The stream paths pass it;
C<$event> is only set by L<Langertha::Role::Streaming/process_stream_data>, the
C<chat_stream_realtime_f> path passes C<undef>. A direct caller may omit
C<\%state> and share the engine's fallback, which is closed when a
C<_process_stream_buffer> flush with C<$final> set ends the stream; a caller
feeding events to C<parse_stream_chunk> one by one should pass its own state.

=cut

sub _finish_stream_state {
  my ( $self, $state ) = @_;
  $state //= $self->_stream_parse_state;
  my $order = $state->{openai_tool_order} or return;
  return unless @$order;
  my $pending = $state->{openai_tool_calls} // {};
  my @names = map { $pending->{$_}{function}{name} // '?' } @$order;
  %$pending = ();
  @$order   = ();
  carp "".( ref $self )." stream ended without a finish_reason; dropping "
    . scalar(@names) . " unfinished tool call(s): " . join( ', ', @names );
  return;
}

=method _finish_stream_state

    $engine->_finish_stream_state(\%state);

Internal: called once when a stream ends (by
L<Langertha::Role::Streaming/process_stream_data> and
L<Langertha::Role::Chat/chat_stream_realtime_f>, and by a final
C<_process_stream_buffer> flush that was given no state). Tool calls still
pending because no chunk carried a C<finish_reason> -- a truncated stream -- are
dropped with one C<carp> naming them, not flushed: their C<arguments> may be
cut off, and a partial JSON string would decode to C<{}>. Clearing them also
keeps them out of the next stream that shares the same state.

=cut

# Tool calling support (MCP) is provided by the tag-driven defaults in
# Langertha::Role::Tools (tool_wire_format => 'openai'). No per-engine copies.

# Image generation

sub image_operation_id { 'createImage' }

sub image_request {
  my ( $self, $prompt, %extra ) = @_;
  return $self->generate_request( $self->image_operation_id, sub { $self->image_response(shift) },
    model  => $self->image_model,
    prompt => $prompt,
    %extra,
  );
}

=method image_request

    my $request = $engine->image_request($prompt, %extra);

Generates an OpenAI-format image generation request for the given
C<$prompt>. Uses C<image_model> (default: C<gpt-image-1>). Accepts
optional C<size>, C<quality>, C<n>, C<response_format> via C<%extra>.
Returns an HTTP request object.

=cut

sub image_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  return $data->{data};
}

=method image_response

    my $images = $engine->image_response($http_response);

Parses an OpenAI-format image generation response. Returns an ArrayRef
of image objects, each with C<url> or C<b64_json> and optionally
C<revised_prompt>.

=cut

sub simple_image {
  my ( $self, $prompt, %extra ) = @_;
  my $request = $self->image_request($prompt, %extra);
  my $response = $self->user_agent->request($request);
  return $request->response_call->($response);
}

=method simple_image

    my $images = $engine->simple_image('A cat in space');

Sends an image generation request and returns the result. Blocks until
the request completes. Returns an ArrayRef of image objects.

=cut

sub _parse_rate_limit_headers {
  my ( $self, $http_response ) = @_;
  require Langertha::RateLimit;
  require Langertha::Moment;
  my %raw = Langertha::RateLimit::_collect_headers($http_response);
  return undef unless %raw;
  my $req_reset = $raw{'x-ratelimit-reset-requests'};
  my $tok_reset = $raw{'x-ratelimit-reset-tokens'};
  # OpenAI-family reset headers are Go time.Duration strings ("6m0s",
  # "2m59.56s", "250ms") — a duration, so they populate *_reset_after; the
  # matching *_reset_at is derived lazily against `received`. A value that is
  # not a Go duration parses to undef and neither half is set (raw keeps it).
  my $req_after = defined $req_reset ? Langertha::RateLimit::_parse_go_duration($req_reset) : undef;
  my $tok_after = defined $tok_reset ? Langertha::RateLimit::_parse_go_duration($tok_reset) : undef;
  return Langertha::RateLimit->new(
    received => Langertha::Moment->now_utc,
    ( defined $raw{'x-ratelimit-limit-requests'}     ? ( requests_limit       => $raw{'x-ratelimit-limit-requests'} + 0 )     : () ),
    ( defined $raw{'x-ratelimit-remaining-requests'} ? ( requests_remaining   => $raw{'x-ratelimit-remaining-requests'} + 0 ) : () ),
    ( defined $req_reset                             ? ( requests_reset       => $req_reset )                                 : () ),
    ( defined $req_after                             ? ( requests_reset_after => $req_after )                                 : () ),
    ( defined $raw{'x-ratelimit-limit-tokens'}       ? ( tokens_limit         => $raw{'x-ratelimit-limit-tokens'} + 0 )       : () ),
    ( defined $raw{'x-ratelimit-remaining-tokens'}   ? ( tokens_remaining     => $raw{'x-ratelimit-remaining-tokens'} + 0 )   : () ),
    ( defined $tok_reset                             ? ( tokens_reset         => $tok_reset )                                 : () ),
    ( defined $tok_after                             ? ( tokens_reset_after   => $tok_after )                                 : () ),
    raw => \%raw,
  );
}

=method _parse_rate_limit_headers

Parses C<x-ratelimit-*> headers from the HTTP response into a
L<Langertha::RateLimit> object. Covers OpenAI, Groq, Cerebras, OpenRouter,
Replicate, and all other OpenAI-compatible engines. Collects the full C<raw>
superset via L<Langertha::RateLimit/_collect_headers>, then normalizes the
Go C<time.Duration> reset strings into L<Langertha::RateLimit/requests_reset_after>
/ L<Langertha::RateLimit/tokens_reset_after> (seconds); the C<*_reset_at>
instants are derived lazily against L<Langertha::RateLimit/received>.

=cut

=seealso

=over

=item * L<Langertha::RateLimit> - Normalized rate limit data

=item * L<Langertha::Engine::OpenAI> - OpenAI engine

=item * L<Langertha::Engine::DeepSeek> - DeepSeek engine

=item * L<Langertha::Engine::Groq> - Groq engine

=item * L<Langertha::Engine::Mistral> - Mistral engine

=item * L<Langertha::Engine::vLLM> - vLLM inference server

=item * L<Langertha::Engine::NousResearch> - Nous Research Hermes engine

=item * L<Langertha::Engine::Perplexity> - Perplexity Sonar engine

=item * L<Langertha::Engine::OllamaOpenAI> - Ollama OpenAI-compatible engine

=item * L<Langertha::Engine::AKIOpenAI> - AKI.IO OpenAI-compatible engine

=back

=cut

1;
