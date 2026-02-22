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

=head1 SYNOPSIS

    use Langertha::Engine::OpenAI;

    my $openai = Langertha::Engine::OpenAI->new(
        api_key      => $ENV{OPENAI_API_KEY},
        model        => 'gpt-4o-mini',
        system_prompt => 'You are a helpful assistant',
        temperature  => 0.7,
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

Provides access to OpenAI's APIs, including GPT models, embeddings, and
Whisper transcription. Composes L<Langertha::Role::OpenAICompatible> for the
standard OpenAI API format.

Popular models: C<gpt-4o-mini> (default, fast), C<gpt-4o> (most capable),
C<o1>/C<o3-mini> (reasoning), C<text-embedding-3-large> (embeddings),
C<whisper-1> (transcription).

Dynamic model listing is supported via L<Langertha::Role::Models/list_models>.
Results are cached for C<models_cache_ttl> seconds (default: 3600).

Get your API key at L<https://platform.openai.com/> and set
C<LANGERTHA_OPENAI_API_KEY> in your environment.

B<THIS API IS WORK IN PROGRESS>

=cut

has compatibility_for_engine => (
  is => 'ro',
  predicate => 'has_compatibility_for_engine',
);

=attr compatibility_for_engine

Optional identifier of the engine this instance is acting as a compatibility
shim for. Used internally when one engine is accessed via another's OpenAI
endpoint.

=cut

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_OPENAI_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_OPENAI_API_KEY or api_key set";
}

sub default_model { 'gpt-4o-mini' }

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://platform.openai.com/docs> - Official OpenAI documentation

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format role

=item * L<Langertha::Role::Tools> - MCP tool calling interface

=item * L<Langertha::Engine::DeepSeek> - DeepSeek (extends this engine)

=item * L<Langertha::Engine::Groq> - Groq (extends this engine)

=item * L<Langertha::Engine::Mistral> - Mistral (extends this engine)

=item * L<Langertha> - Main Langertha documentation

=back

=cut

1;
