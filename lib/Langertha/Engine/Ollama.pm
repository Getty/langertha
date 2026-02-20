package Langertha::Engine::Ollama;
# ABSTRACT: Ollama API
our $VERSION = '0.101';
use Moose;
use File::ShareDir::ProjectDistDir qw( :all );
use Carp qw( croak );
use JSON::MaybeXS;

use Langertha::Engine::OpenAI;

with 'Langertha::Role::'.$_ for (qw(
  JSON
  HTTP
  OpenAPI
  Models
  Seed
  Temperature
  ContextSize
  ResponseSize
  SystemPrompt
  Chat
  Embedding
  Streaming
));

sub openai {
  my ( $self, %args ) = @_;
  my $url = $self->url || $self->openapi->openapi_document->get('/servers/0/url');
  return Langertha::Engine::OpenAI->new(
    url => $self->url.'/v1',
    model => $self->model,
    $self->embedding_model ? ( embedding_model => $self->embedding_model ) : (),
    $self->chat_model ? ( chat_model => $self->chat_model ) : (),
    $self->has_system_prompt ? ( system_prompt => $self->system_prompt ) : (),
    $self->has_temperature ? ( temperature => $self->temperature ) : (),
    api_key => 'ollama',
    compatibility_for_engine => $self,
    supported_operations => [qw(
      createChatCompletion
      createEmbedding
    )],
    %args,
  );
}

sub new_openai {
  my ( $class, %args ) = @_;
  my $tools = delete $args{tools} || [];
  my $self = $class->new(%args);
  return $self->openai( tools => $tools );
}

sub default_model { 'llama3.3' }
sub default_embedding_model { 'mxbai-embed-large' }

sub openapi_file { yaml => dist_file('Langertha','ollama.yaml') };

has keep_alive => (
  isa => 'Str',
  is => 'ro',
  predicate => 'has_keep_alive',
);

has json_format => (
  isa => 'Bool',
  is => 'ro',
  default => sub {0},
);

sub embedding_request {
  my ( $self, $prompt, %extra ) = @_;
  return $self->generate_request( generateEmbeddings => sub { $self->embedding_response(shift) },
    model => $self->embedding_model,
    prompt => $prompt,
    %extra,
  );
}

sub embedding_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  # tracing
  return $data->{embedding};
}

sub chat_request {
  my ( $self, $messages, %extra ) = @_;
  return $self->generate_request( generateChat => sub { $self->chat_response(shift) },
    model => $self->chat_model,
    messages => $messages,
    stream => JSON->false,
    $self->json_format ? ( format => 'json' ) : (),
    $self->has_keep_alive ? ( keep_alive => $self->keep_alive ) : (),
    options => {
      $self->has_temperature ? ( temperature => $self->temperature ) : (),
      $self->has_context_size ? ( num_ctx => $self->get_context_size ) : (),
      $self->get_response_size ? ( num_predict => $self->get_response_size ) : (),
      $self->has_seed ? ( seed => $self->seed )
        : $self->randomize_seed ? ( seed => $self->random_seed ) : (),
      $extra{options} ? (%{delete $extra{options}}) : (),
    },
    %extra,
  );
}

sub chat_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  # tracing
  my @messages = $data->{message};
  return $messages[0]->{content};
}

sub tags { $_[0]->tags_request }
sub tags_request {
  my ( $self ) = @_;
  return $self->generate_request( getModels => sub { $self->tags_response(shift) } );
}

sub tags_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  my @model_list = map { $_->{model} } @{$data->{models}};
  $self->models(\@model_list);
  return $data->{models};
}

sub simple_tags {
  my ( $self ) = @_;
  my $request = $self->tags;
  my $response = $self->user_agent->request($request);
  return $request->response_call->($response);
}

sub ps { $_[0]->ps_request }
sub ps_request {
  my ( $self ) = @_;
  return $self->generate_request( getRunningModels => sub { $self->ps_response(shift) } );
}

sub ps_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  return $data->{models};
}

sub simple_ps {
  my ( $self ) = @_;
  my $request = $self->ps;
  my $response = $self->user_agent->request($request);
  return $request->response_call->($response);
}

# Dynamic model listing (wrapper around simple_tags with caching)
sub list_models {
  my ($self, %opts) = @_;

  # Check cache unless force_refresh requested
  unless ($opts{force_refresh}) {
    my $cache = $self->_models_cache;
    if ($cache->{timestamp} && time - $cache->{timestamp} < $self->models_cache_ttl) {
      return $opts{full} ? $cache->{models} : $cache->{model_ids};
    }
  }

  # Fetch from API via simple_tags
  my $models = $self->simple_tags;

  # Extract IDs and update cache
  my @model_ids = map { $_->{model} } @$models;
  $self->_models_cache({
    timestamp => time,
    models => $models,
    model_ids => \@model_ids,
  });

  return $opts{full} ? $models : \@model_ids;
}

sub stream_format { 'ndjson' }

sub chat_stream_request {
  my ( $self, $messages, %extra ) = @_;
  return $self->generate_request( generateChat => sub {},
    model => $self->chat_model,
    messages => $messages,
    stream => JSON->true,
    $self->json_format ? ( format => 'json' ) : (),
    $self->has_keep_alive ? ( keep_alive => $self->keep_alive ) : (),
    options => {
      $self->has_temperature ? ( temperature => $self->temperature ) : (),
      $self->has_context_size ? ( num_ctx => $self->get_context_size ) : (),
      $self->get_response_size ? ( num_predict => $self->get_response_size ) : (),
      $self->has_seed ? ( seed => $self->seed )
        : $self->randomize_seed ? ( seed => $self->random_seed ) : (),
      $extra{options} ? (%{delete $extra{options}}) : (),
    },
    %extra,
  );
}

sub parse_stream_chunk {
  my ( $self, $data ) = @_;

  my $content = $data->{message}{content} // '';
  my $is_done = $data->{done} ? 1 : 0;

  require Langertha::Stream::Chunk;
  return Langertha::Stream::Chunk->new(
    content => $content,
    raw => $data,
    is_final => $is_done,
    $data->{model} ? (model => $data->{model}) : (),
    $is_done && $data->{done_reason} ? (finish_reason => $data->{done_reason}) : (),
    $is_done ? (usage => {
      $data->{eval_count} ? (completion_tokens => $data->{eval_count}) : (),
      $data->{prompt_eval_count} ? (prompt_tokens => $data->{prompt_eval_count}) : (),
    }) : (),
  );
}

__PACKAGE__->meta->make_immutable;

=head1 SYNOPSIS

  use Langertha::Engine::Ollama;

  my $ollama = Langertha::Engine::Ollama->new(
    url => $ENV{OLLAMA_URL},
    model => 'llama3.3',
    system_prompt => 'You are a helpful assistant',
    context_size => 2048,
    temperature => 0.5,
  );

  print($ollama->simple_chat('Say something nice'));

  my $embedding = $ollama->embedding($content);

  # Get OpenAI compatible API access to Ollama
  my $ollama_openai = $ollama->openai;

  # List available models
  my $models = $ollama->simple_tags;

  # Show running models
  my $running = $ollama->simple_ps;

=head1 DESCRIPTION

This module provides access to Ollama, which runs large language models locally.
Ollama supports many popular open-source models with various sizes and capabilities.

B<Popular Models (February 2026):>

=over 4

=item * B<llama3.3> - Meta's Llama 3.3 70B with 128k context (default). Excellent general-purpose model with broad tool support.

=item * B<llama3.2> - Meta's Llama 3.2 includes small models (1B, 3B) for efficient local inference.

=item * B<qwen3> - Latest Qwen 3 generation with enhanced reasoning. Qwen3-30B recommended for most teams (delivers 90%+ flagship power at lower cost).

=item * B<qwen2.5> - Qwen 2.5 family (up to 72B) with strong multilingual support and 128k context. Excellent for general tasks.

=item * B<qwen2.5-coder> - Qwen 2.5 specialized for code generation and programming tasks.

=item * B<deepseek-coder-v2> - DeepSeek's coding-specialized model. Excellent for software development.

=item * B<mixtral> - Mistral's mixture-of-experts model (8x22B). Cost-effective performance.

=item * B<mistral> - Mistral models including latest Mistral 3 family (3B, 8B, 14B).

=item * B<codestral> - Mistral's code-specialized model.

=item * B<mxbai-embed-large> - Embedding model (default for embeddings).

=back

B<Model Selection Tips:>

=over 4

=item * For general tasks: qwen2.5-72b or llama3.3

=item * For coding: deepseek-coder-v2 or qwen2.5-coder

=item * For reasoning: llama3.3 or qwen3

=item * For cost-effective performance: mixtral-8x22b

=item * For low-resource systems: llama3.2-3b or qwen3-30b

=back

B<Features:>

=over 4

=item * Run models completely locally

=item * No API key required

=item * Chat completions with streaming

=item * Embeddings

=item * Custom models and quantization

=item * OpenAI-compatible API access via openai() method

=item * JSON format output support

=item * Keep-alive model loading control

=item * Dynamic model listing with caching

=back

B<THIS API IS WORK IN PROGRESS>

=head1 LISTING AVAILABLE MODELS

Fetch models from your local Ollama instance:

  # Get simple list of model names
  my $model_ids = $ollama->list_models;
  # Returns: ['llama3.3', 'qwen2.5', ...]

  # Get full model objects with metadata
  my $models = $ollama->list_models(full => 1);

  # Force refresh (bypass cache)
  my $models = $ollama->list_models(force_refresh => 1);

  # Or use the original method
  my $tags = $ollama->simple_tags;

B<Caching:> Results are cached for 1 hour. Configure TTL via C<models_cache_ttl>
or clear manually with C<clear_models_cache>.

=head1 HOW TO INSTALL OLLAMA

L<https://github.com/ollama/ollama/tree/main>

To pull a model:

  ollama pull llama3.3
  ollama pull qwen3

To list available models from Ollama library:

  ollama list

=head1 SEE ALSO

=over 4

=item * L<https://ollama.com/library> - Ollama model library

=item * L<Langertha::Engine::OpenAI> - OpenAI compatibility layer

=item * L<Langertha> - Main Langertha documentation

=back

=cut
