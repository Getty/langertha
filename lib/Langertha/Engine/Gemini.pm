package Langertha::Engine::Gemini;
# ABSTRACT: Google Gemini API
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );
use JSON::MaybeXS;
use Langertha::ToolChoice;
use Langertha::Response;
use Langertha::ToolCall;
use Langertha::CachedContent;

extends 'Langertha::Engine::Remote';

with map { 'Langertha::Role::'.$_ } qw(
  Models
  Chat
  Temperature
  ReasoningEffort
  ResponseSize
  SystemPrompt
  ResponseFormat
  Streaming
  Tools
  CachedContent
);

sub _build_reasoning_wire_format { 'gemini' }

# Gemini splits its reasoning knob by model generation: Gemini 2.5-* takes
# an integer thinking_budget (no level vocabulary), Gemini 3 takes a
# thinkingLevel (minimal|low|medium|high, clamped to the model family's
# subset by Langertha::Reasoning). Exactly one native control is honored per
# model. Reflect that in the capability flags so callers can ask
# supports('thinking_budget') vs supports('reasoning_effort') and get the
# truth for the configured model.
#
# The same around also gates cached_content: explicit cachedContent
# resources are an "on" feature for Gemini 2.5+ and Gemini 3. Older
# generations (1.x, 2.0) don't accept the cachedContents REST endpoints,
# so we drop the flag there.
around engine_capabilities => sub {
  my ( $orig, $self, @rest ) = @_;
  my $caps = $self->$orig(@rest);
  my $model = $self->can('chat_model') ? ( $self->chat_model // '' ) : '';
  if ( $model =~ /\Agemini-2\.5/ ) {
    $caps->{thinking_budget} = 1;
    delete $caps->{reasoning_effort};
    $caps->{cached_content} = 1;
  }
  elsif ( $model =~ /\Agemini-3/ ) {
    # Gemini 3 (and any future unknown Gemini generation) keeps the
    # default reasoning_effort cap; thinking_budget is not advertised.
    delete $caps->{thinking_budget};
    $caps->{cached_content} = 1;
  }
  else {
    delete $caps->{thinking_budget};
    delete $caps->{cached_content};
  }
  return $caps;
};

=head1 SYNOPSIS

    use Langertha::Engine::Gemini;

    my $gemini = Langertha::Engine::Gemini->new(
        api_key      => $ENV{GEMINI_API_KEY},
        model        => 'gemini-3-flash-preview',
        response_size => 4096,
        temperature  => 0.7,
    );

    # Simple chat
    my $response = $gemini->simple_chat('Explain quantum computing in simple terms');
    print $response;

    # Streaming
    $gemini->simple_chat_stream(sub {
        my ($chunk) = @_;
        print $chunk->content;
    }, 'Write a poem about Perl');

    # Async with Future::AsyncAwait
    use Future::AsyncAwait;

    async sub ask_gemini {
        my $response = await $gemini->simple_chat_f(
            'What are the benefits of functional programming?'
        );
        say $response;
    }

=head1 DESCRIPTION

Provides access to Google's Gemini models via the Generative Language API.
Gemini models support multimodal input (text, code, images) and long context
windows.

Available models include C<gemini-3-flash-preview> (fast with thinking,
default), C<gemini-3.1-pro-preview> (most capable), C<gemini-3.1-flash-lite>
(cost-efficient workhorse), and the image-generation models
C<gemini-3.1-flash-image-preview> and C<gemini-3-pro-image-preview>. All
Gemini 3 models are currently served as preview. The C<gemini-2.5-*>
generation is still served but now classed as previous-generation. The
default API endpoint is C<https://generativelanguage.googleapis.com>.

B<THIS API IS WORK IN PROGRESS>

=cut

sub default_response_size { 2048 }

sub content_format { 'gemini' }

has api_key => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_GEMINI_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_GEMINI_API_KEY or api_key set";
}

=attr api_key

The Google Generative Language API key. If not provided, reads from
C<LANGERTHA_GEMINI_API_KEY> environment variable. Get your key at
L<https://aistudio.google.com/app/apikey>. Required.

=cut

has '+url' => (
  lazy => 1,
  default => sub { 'https://generativelanguage.googleapis.com' },
);

has cached_content => (
  is        => 'rw',
  isa       => 'Maybe[Langertha::CachedContent]',
  predicate => 'has_cached_content',
  clearer   => 'clear_cached_content',
);

=attr cached_content

Optional L<Langertha::CachedContent> resource bound to this engine. When
set, every chat request (C<chat>, C<chat_stream>, C<simple_chat_f>, …)
injects C<cachedContent =E<gt> '{name}'> into the generateContent body
so the model serves the request against the cached context.

Lifecycle (create / get / list / update / delete) is on the role —
L<Langertha::Role::CachedContent/create_cached_content_f> and friends.
Bind a freshly created resource with C<< $engine->cached_content($cc) >>.

Source URL: L<https://ai.google.dev/api/generate-content> (the
C<cachedContent> field on a generateContent body).

=cut

sub default_model { 'gemini-3-flash-preview' }

sub chat_request {
  my ( $self, $messages, %extra ) = @_;

  # Translate tool_choice (canonical / OpenAI / Anthropic shapes) into
  # Gemini's toolConfig.functionCallingConfig form.
  if ( exists $extra{tool_choice} && defined $extra{tool_choice} ) {
    my $tc = Langertha::ToolChoice->from_hash( delete $extra{tool_choice} );
    if ($tc) {
      my $cfg = $tc->to( $self->tool_wire_format );
      $extra{toolConfig} = $cfg if $cfg;
    }
  }

  # Convert messages to Gemini format
  my @gemini_contents;
  my $system_instruction;

  for my $message (@{$messages}) {
    if ($message->{role} eq 'system') {
      # Gemini uses systemInstruction field for system messages
      $system_instruction .= "\n\n" if $system_instruction;
      $system_instruction .= $message->{content};
    } elsif ($message->{parts}) {
      # Already in Gemini format (e.g. from format_tool_results)
      push @gemini_contents, $message;
    } else {
      # Convert role: 'assistant' -> 'model' for Gemini
      my $role = $message->{role} eq 'assistant' ? 'model' : $message->{role};
      push @gemini_contents, {
        role => $role,
        parts => [{ text => $message->{content} }],
      };
    }
  }

  # Build the URL with model and API key
  my $model_name = $self->chat_model;
  my $url = $self->url . "/v1beta/models/${model_name}:generateContent?key=" . $self->api_key;

  my %request_body = (
    contents => \@gemini_contents,
  );

  # Add system instruction if present
  if ($system_instruction) {
    $request_body{systemInstruction} = {
      parts => [{ text => $system_instruction }],
    };
  }

  # Reference an explicit cachedContent resource by name when one was bound
  # via $engine->cached_content (karr #22). The REST contract names the field
  # `cachedContent` and accepts the resource name as a plain string —
  # https://ai.google.dev/api/generate-content (cachedContent field).
  if ( $self->can('cached_content') && defined $self->cached_content ) {
    my $cc = $self->cached_content;
    croak "Langertha::Engine::Gemini: cached_content must be a Langertha::CachedContent with a 'name'"
      unless ref($cc) && eval { $cc->isa('Langertha::CachedContent') && $cc->has_name };
    $request_body{cachedContent} = $cc->name;
  }

  # Add generation config
  my %generation_config;
  if ($self->get_response_size) {
    $generation_config{maxOutputTokens} = $self->get_response_size;
  }
  if ($self->has_temperature) {
    $generation_config{temperature} = $self->temperature;
  }

  # Translate response_format -> Gemini's generationConfig.responseSchema /
  # responseMimeType. Accepts the OpenAI-shape response_format hash so that
  # callers can hand the same payload to any engine.
  if ( $self->has_response_format ) {
    my $rf = $self->response_format;
    my $type = ref($rf) eq 'HASH' ? ( $rf->{type} // '' ) : '';
    if ( $type eq 'json_object' ) {
      $generation_config{responseMimeType} = 'application/json';
    }
    elsif ( $type eq 'json_schema'
        && ref( $rf->{json_schema} ) eq 'HASH'
        && ref( $rf->{json_schema}{schema} ) eq 'HASH' ) {
      $generation_config{responseMimeType} = 'application/json';
      $generation_config{responseSchema}   = $rf->{json_schema}{schema};
    }
  }

  # Merge reasoning effort / thinking_budget ->
  # generationConfig.thinkingConfig.thinkingLevel (Gemini 3) or
  # thinkingConfig.thinkingBudget (Gemini 2.5). Langertha::Reasoning owns
  # the per-model placement; this just decides whether to emit anything.
  if ( $self->has_reasoning_effort || $self->has_thinking_budget ) {
    %generation_config = ( %generation_config, $self->reasoning_kwargs );
  }

  $request_body{generationConfig} = \%generation_config if %generation_config;

  return $self->generate_http_request(
    POST => $url,
    sub { $self->chat_response(shift) },
    %request_body,
    %extra,
  );
}

sub update_request {
  my ( $self, $request ) = @_;
  $request->header('content-type', 'application/json');
}

sub chat_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);

  # Gemini response format: candidates[0].content.parts[].text
  my $candidates = $data->{candidates} || [];
  my $text = '';
  my $finish_reason;
  my $thinking;
  if (@$candidates) {
    my $candidate = $candidates->[0];
    my $content = $candidate->{content} || {};
    my $parts = $content->{parts} || [];
    my @text_parts;
    my @thought_parts;
    for my $part (@$parts) {
      next unless exists $part->{text};
      if ($part->{thought}) {
        push @thought_parts, $part->{text};
      } else {
        push @text_parts, $part->{text};
      }
    }
    $text = join('', @text_parts);
    $thinking = join("\n", @thought_parts) if @thought_parts;
    $finish_reason = $candidate->{finishReason};
  }

  # Normalize Gemini usage metadata. cachedContentTokenCount is surfaced
  # when present so callers can monitor cache-hit rate (karr #22, 22e).
  # See https://ai.google.dev/api/generate-content (usageMetadata).
  my $usage;
  if (my $um = $data->{usageMetadata}) {
    $usage = {
      prompt_tokens     => $um->{promptTokenCount},
      completion_tokens => $um->{candidatesTokenCount},
      total_tokens      => $um->{totalTokenCount},
    };
    if ( defined $um->{cachedContentTokenCount} ) {
      $usage->{cached_content_token_count} = $um->{cachedContentTokenCount};
    }
  }

  my @tcs = Langertha::ToolCall->extract( $self->tool_wire_format, $data );
  return Langertha::Response->new(
    content       => $text,
    raw           => $data,
    $data->{modelVersion} ? ( model => $data->{modelVersion} ) : (),
    defined $finish_reason ? ( finish_reason => $finish_reason ) : (),
    $usage ? ( usage => $usage ) : (),
    defined $thinking ? ( thinking => $thinking ) : (),
    @tcs ? ( tool_calls => [ @tcs ] ) : (),
  );
}

sub stream_format { 'sse' }

sub chat_stream_request {
  my ( $self, $messages, %extra ) = @_;

  # Same tool_choice translation as chat_request.
  if ( exists $extra{tool_choice} && defined $extra{tool_choice} ) {
    my $tc = Langertha::ToolChoice->from_hash( delete $extra{tool_choice} );
    if ($tc) {
      my $cfg = $tc->to( $self->tool_wire_format );
      $extra{toolConfig} = $cfg if $cfg;
    }
  }

  # Convert messages to Gemini format (same as non-streaming)
  my @gemini_contents;
  my $system_instruction;

  for my $message (@{$messages}) {
    if ($message->{role} eq 'system') {
      $system_instruction .= "\n\n" if $system_instruction;
      $system_instruction .= $message->{content};
    } else {
      my $role = $message->{role} eq 'assistant' ? 'model' : $message->{role};
      push @gemini_contents, {
        role => $role,
        parts => [{ text => $message->{content} }],
      };
    }
  }

  # Build the URL for streaming endpoint
  my $model_name = $self->chat_model;
  my $url = $self->url . "/v1beta/models/${model_name}:streamGenerateContent?key=" . $self->api_key . "&alt=sse";

  my %request_body = (
    contents => \@gemini_contents,
  );

  if ($system_instruction) {
    $request_body{systemInstruction} = {
      parts => [{ text => $system_instruction }],
    };
  }

  # Reference an explicit cachedContent resource by name when one was bound
  # via $engine->cached_content (karr #22). Same wire as chat_request.
  if ( $self->can('cached_content') && defined $self->cached_content ) {
    my $cc = $self->cached_content;
    croak "Langertha::Engine::Gemini: cached_content must be a Langertha::CachedContent with a 'name'"
      unless ref($cc) && eval { $cc->isa('Langertha::CachedContent') && $cc->has_name };
    $request_body{cachedContent} = $cc->name;
  }

  my %generation_config;
  if ($self->get_response_size) {
    $generation_config{maxOutputTokens} = $self->get_response_size;
  }
  if ($self->has_temperature) {
    $generation_config{temperature} = $self->temperature;
  }

  if ( $self->has_reasoning_effort ) {
    %generation_config = ( %generation_config, $self->reasoning_kwargs );
  }

  $request_body{generationConfig} = \%generation_config if %generation_config;

  return $self->generate_http_request(
    POST => $url,
    sub {},
    %request_body,
    %extra,
  );
}

sub parse_stream_chunk {
  my ( $self, $data, $event ) = @_;

  require Langertha::Stream::Chunk;

  # Gemini streaming format is similar to non-streaming
  my $candidates = $data->{candidates} || [];
  return undef unless @$candidates;

  my $candidate = $candidates->[0];
  my $content = $candidate->{content} || {};
  my $parts = $content->{parts} || [];

  my $text = '';
  $text = $parts->[0]->{text} if @$parts && $parts->[0]->{text};

  my $finish_reason = $candidate->{finishReason};
  my $is_final = defined $finish_reason && $finish_reason ne '';

  return Langertha::Stream::Chunk->new(
    content => $text,
    raw => $data,
    is_final => $is_final,
    $finish_reason ? (finish_reason => $finish_reason) : (),
    $data->{usageMetadata} ? (usage => $data->{usageMetadata}) : (),
  );
}

# Dynamic model listing with token pagination
sub list_models_request {
  my ($self, %params) = @_;
  my $url = $self->url . '/v1beta/models?key=' . $self->api_key;

  # Add pagination params if provided
  if (%params) {
    require URI;
    my $uri = URI->new($url);
    my %query = $uri->query_form;
    $uri->query_form(%query, %params);
    $url = $uri->as_string;
  }

  return $self->generate_http_request(
    GET => $url,
    sub { $self->list_models_response(shift) },
  );
}

sub list_models_response {
  my ($self, $response) = @_;
  my $data = $self->parse_response($response);
  return $data;
}

sub _fetch_all_models {
  my ($self) = @_;
  my @all_models;
  my $page_token;

  do {
    my $request = $self->list_models_request(
      $page_token ? (pageToken => $page_token) : ()
    );
    my $response = $self->user_agent->request($request);
    my $data = $request->response_call->($response);

    push @all_models, @{$data->{models} || []};
    $page_token = $data->{nextPageToken};
  } while ($page_token);

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
  # Gemini uses 'name' field like "models/gemini-2.0-flash"
  my @model_ids = map {
    my $name = $_->{name};
    $name =~ s{^models/}{};  # Strip "models/" prefix
    $name;
  } @$models;

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

Fetches available models from the Gemini API using token pagination. Returns
an ArrayRef of model ID strings (with the C<models/> prefix stripped) by
default, or full model objects when C<full => 1> is passed. Results are cached
for C<models_cache_ttl> seconds (default: 3600).

=cut

# Tool calling support (MCP) is the tag-driven default in Langertha::Role::Tools.
sub _build_tool_wire_format { 'gemini' }

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://aistudio.google.com/status> - Google AI Studio service status

=item * L<https://ai.google.dev/gemini-api/docs> - Official Gemini API documentation

=item * L<https://aistudio.google.com/> - Google AI Studio for testing

=item * L<Langertha::Role::Chat> - Chat interface methods

=item * L<Langertha::Role::Tools> - MCP tool calling interface

=item * L<Langertha::Role::Streaming> - Streaming support (SSE format)

=item * L<Langertha::Engine::Anthropic> - Another non-OpenAI-compatible engine

=back

=cut

1;
