package Langertha::Engine::OpenAI;
# ABSTRACT: OpenAI API
our $VERSION = '0.101';
use Moose;
use Carp qw( croak );

with 'Langertha::Role::'.$_ for (qw(
  JSON
  HTTP
  OpenAICompatible
  OpenAPI
  Models
  Temperature
  ResponseSize
  ResponseFormat
  SystemPrompt
  Streaming
  Chat
  Embedding
  Transcription
));

with 'Langertha::Role::Tools';

has compatibility_for_engine => (
  is => 'ro',
  predicate => 'has_compatibility_for_engine',
);

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_OPENAI_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_OPENAI_API_KEY or api_key set";
}

sub default_model { 'gpt-4o-mini' }

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
embeddings, and Whisper transcription. It composes
L<Langertha::Role::OpenAICompatible> for the OpenAI API format methods.

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

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format role

=item * L<Langertha::Role::Chat> - Chat interface

=item * L<Langertha::Role::Embedding> - Embedding interface

=item * L<Langertha::Role::Transcription> - Transcription interface

=item * L<Langertha> - Main Langertha documentation

=back

=cut
