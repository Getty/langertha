package Langertha::Engine::OpenAI;
# ABSTRACT: OpenAI API
our $VERSION = '0.101';
use Moose;
use File::ShareDir::ProjectDistDir qw( :all );
use Carp qw( croak );
use JSON::MaybeXS;

with 'Langertha::Role::'.$_ for (qw(
  JSON
  HTTP
  OpenAPI
  Models
  Temperature
  ResponseSize
  ResponseFormat
  SystemPrompt
  Chat
  Embedding
  Transcription
  Streaming
));

has compatibility_for_engine => (
  is => 'ro',
  predicate => 'has_compatibility_for_engine',
);

has api_key => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_OPENAI_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_OPENAI_API_KEY or api_key set";
}

sub update_request {
  my ( $self, $request ) = @_;
  $request->header('Authorization', 'Bearer '.$self->api_key);
}

sub default_model { 'gpt-4o-mini' }
sub default_embedding_model { 'text-embedding-3-large' }
sub default_transcription_model { 'whisper-1' }

sub openapi_file { yaml => dist_file('Langertha','openai.yaml') };

# Dynamic model listing
sub list_models_request {
  my ($self) = @_;
  return $self->generate_http_request(
    GET => $self->url.'/v1/models',
    sub { $self->list_models_response(shift) },
  );
}

sub list_models_response {
  my ($self, $response) = @_;
  my $data = $self->parse_response($response);
  return $data->{data};
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

  # Fetch from API
  my $request = $self->list_models_request;
  my $response = $self->user_agent->request($request);
  my $models = $request->response_call->($response);

  # Extract IDs and update cache
  my @model_ids = map { $_->{id} } @$models;
  $self->_models_cache({
    timestamp => time,
    models => $models,
    model_ids => \@model_ids,
  });

  return $opts{full} ? $models : \@model_ids;
}

sub embedding_operation_id { 'createEmbedding' }

sub embedding_request {
  my ( $self, $input, %extra ) = @_;
  return $self->generate_request( $self->embedding_operation_id, sub { $self->embedding_response(shift) },
    model => $self->embedding_model,
    input => $input,
    %extra,
  );
}

sub embedding_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  # tracing
  my @objects = @{$data->{data}};
  return $objects[0]->{embedding};
}

sub chat_operation_id { 'createChatCompletion' }

sub chat_request {
  my ( $self, $messages, %extra ) = @_;
  return $self->generate_request( $self->chat_operation_id, sub { $self->chat_response(shift) },
    model => $self->chat_model,
    messages => $messages,
    $self->get_response_size ? ( max_tokens => $self->get_response_size ) : (),
    $self->has_response_format ? ( response_format => $self->response_format ) : (),
    $self->has_temperature ? ( temperature => $self->temperature ) : (),
    stream => JSON->false,
    # $self->has_seed ? ( seed => $self->seed )
    #   : $self->randomize_seed ? ( seed => round(rand(100_000_000)) ) : (),
    %extra,
  );
}

sub chat_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  # tracing
  my @messages = map { $_->{message} } @{$data->{choices}};
  return $messages[0]->{content};
}

sub transcription_operation_id { 'createTranscription' }

sub transcription_request {
  my ( $self, $file, %extra ) = @_;
  return $self->generate_request( $self->transcription_operation_id, sub { $self->transcription_response(shift) },
    file => [ $file ],
    $self->transcription_model ? ( model => $self->transcription_model ) : (),
    %extra,
  );
}

sub transcription_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  return $data->{text};
}

sub stream_format { 'sse' }

sub chat_stream_request {
  my ( $self, $messages, %extra ) = @_;
  return $self->generate_request( $self->chat_operation_id, sub {},
    model => $self->chat_model,
    messages => $messages,
    $self->get_response_size ? ( max_tokens => $self->get_response_size ) : (),
    $self->has_response_format ? ( response_format => $self->response_format ) : (),
    $self->has_temperature ? ( temperature => $self->temperature ) : (),
    stream => JSON->true,
    %extra,
  );
}

sub parse_stream_chunk {
  my ( $self, $data, $event ) = @_;

  return undef unless $data && $data->{choices};

  my $choice = $data->{choices}[0];
  return undef unless $choice;

  my $content = $choice->{delta}{content} // '';
  my $finish_reason = $choice->{finish_reason};

  require Langertha::Stream::Chunk;
  return Langertha::Stream::Chunk->new(
    content => $content,
    raw => $data,
    is_final => defined $finish_reason,
    defined $finish_reason ? (finish_reason => $finish_reason) : (),
    $data->{model} ? (model => $data->{model}) : (),
    $data->{usage} ? (usage => $data->{usage}) : (),
  );
}

# Tool calling support (MCP)

sub format_tools {
  my ( $self, $mcp_tools ) = @_;
  return [map {
    {
      type     => 'function',
      function => {
        name        => $_->{name},
        description => $_->{description},
        parameters  => $_->{inputSchema},
      },
    }
  } @$mcp_tools];
}

sub response_tool_calls {
  my ( $self, $data ) = @_;
  my $choice = $data->{choices}[0] or return [];
  my $msg = $choice->{message} or return [];
  return $msg->{tool_calls} // [];
}

sub extract_tool_call {
  my ( $self, $tc ) = @_;
  my $args = $tc->{function}{arguments};
  $args = $self->json->decode($args) if $args && !ref $args;
  return ( $tc->{function}{name}, $args );
}

sub response_text_content {
  my ( $self, $data ) = @_;
  my $choice = $data->{choices}[0] or return '';
  return $choice->{message}{content} // '';
}

sub format_tool_results {
  my ( $self, $data, $results ) = @_;
  my $choice = $data->{choices}[0];
  return (
    { role => 'assistant', content => $choice->{message}{content},
      tool_calls => $choice->{message}{tool_calls} },
    map {
      my $r = $_;
      {
        role         => 'tool',
        tool_call_id => $r->{tool_call}{id},
        content      => $self->json->encode($r->{result}{content}),
      }
    } @$results
  );
}

with 'Langertha::Role::Tools';

__PACKAGE__->meta->make_immutable;

=head1 SYNOPSIS

  use Langertha::Engine::OpenAI;

  # Basic chat
  my $openai = Langertha::Engine::OpenAI->new(
    api_key => $ENV{OPENAI_API_KEY},
    model => 'gpt-4o-mini',
    system_prompt => 'You are a helpful assistant',
    temperature => 0.7,
  );

  my $response = $openai->simple_chat('Say something nice');
  print $response;

  # Embeddings
  my $embedding = $openai->embedding('Some text to embed');

  # Transcription (Whisper)
  my $text = $openai->transcription('/path/to/audio.mp3');

  # Async with Future::AsyncAwait
  use Future::AsyncAwait;

  async sub ask_gpt {
    my $response = await $openai->simple_chat_f('What is Perl?');
    say $response;
  }

=head1 DESCRIPTION

This module provides access to OpenAI's APIs, including GPT models,
embeddings, and Whisper transcription.

B<Popular Models:>

=over 4

=item * gpt-4o-mini - Fast, cost-effective (default for chat)

=item * gpt-4o - Most capable GPT-4 model

=item * o1 - Advanced reasoning model

=item * o3-mini - Fast reasoning model

=item * text-embedding-3-large - Embeddings (default)

=item * whisper-1 - Audio transcription (default)

=back

B<Features:>

=over 4

=item * Chat completions with streaming

=item * Text embeddings

=item * Audio transcription (Whisper)

=item * Response format control (JSON mode)

=item * Temperature and response size control

=item * System prompts

=item * Async/await support via Future::AsyncAwait

=item * Dynamic model discovery via API

=back

B<THIS API IS WORK IN PROGRESS>

=head1 LISTING AVAILABLE MODELS

You can dynamically fetch the list of available models from the OpenAI API:

  # Get simple list of model IDs
  my $model_ids = $engine->list_models;
  # Returns: ['gpt-4o', 'gpt-4o-mini', 'o1', ...]

  # Get full model objects with metadata
  my $models = $engine->list_models(full => 1);
  # Returns: [{id => 'gpt-4o', created => 1715367049, ...}, ...]

  # Force refresh (bypass cache)
  my $models = $engine->list_models(force_refresh => 1);

B<Caching:> Results are cached for 1 hour by default. Configure the TTL:

  my $engine = Langertha::Engine::OpenAI->new(
    api_key => $ENV{OPENAI_API_KEY},
    models_cache_ttl => 1800, # 30 minutes
  );

  # Clear the cache manually
  $engine->clear_models_cache;

=head1 GETTING AN API KEY

Sign up at L<https://platform.openai.com/> and generate an API key.

Set the environment variable:

  export OPENAI_API_KEY=your-key-here
  # Or use LANGERTHA_OPENAI_API_KEY

=head1 SEE ALSO

=over 4

=item * L<https://platform.openai.com/docs> - Official OpenAI documentation

=item * L<Langertha::Role::Chat> - Chat interface

=item * L<Langertha::Role::Embedding> - Embedding interface

=item * L<Langertha::Role::Transcription> - Transcription interface

=item * L<Langertha> - Main Langertha documentation

=back

=cut
