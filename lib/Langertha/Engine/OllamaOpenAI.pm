package Langertha::Engine::OllamaOpenAI;
# ABSTRACT: Ollama via OpenAI-compatible API
our $VERSION = '0.203';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAIBase';

with 'Langertha::Role::Embedding';
with 'Langertha::Role::Tools';

=head1 SYNOPSIS

    use Langertha::Engine::OllamaOpenAI;

    # Direct construction (url with /v1 suffix is required)
    my $ollama_oai = Langertha::Engine::OllamaOpenAI->new(
        url   => 'http://localhost:11434/v1',
        model => 'llama3.3',
    );

    print $ollama_oai->simple_chat('Hello!');

    # Streaming
    $ollama_oai->simple_chat_stream(sub {
        print shift->content;
    }, 'Tell me about Perl');

    # Preferred: create via Ollama's openai() method (appends /v1 automatically)
    use Langertha::Engine::Ollama;

    my $ollama = Langertha::Engine::Ollama->new(
        url   => 'http://localhost:11434',
        model => 'llama3.3',
    );
    my $oai = $ollama->openai;
    print $oai->simple_chat('Hello via OpenAI format!');

=head1 DESCRIPTION

Provides access to Ollama's OpenAI-compatible C</v1> API endpoint. Composes
L<Langertha::Role::OpenAICompatible> for the standard OpenAI format.

C<url> is required and must include the C</v1> path prefix (e.g.,
C<http://localhost:11434/v1>). When using L<Langertha::Engine::Ollama/openai>,
the C</v1> suffix is appended automatically. The API key defaults to
C<'ollama'> since Ollama does not require authentication.

Supports chat completions (SSE streaming), embeddings (default:
C<mxbai-embed-large>), MCP tool calling, and dynamic model listing.
Transcription is not supported.

For the native Ollama API with C<keep_alive>, C<seed>, C<context_size>,
NDJSON streaming, and Hermes tool calling, use L<Langertha::Engine::Ollama>.

B<THIS API IS WORK IN PROGRESS>

=cut

has '+url' => (
  required => 1,
);

sub default_model { croak "".(ref $_[0])." requires model to be set" }
sub default_embedding_model { 'mxbai-embed-large' }

sub _build_supported_operations {[qw( createChatCompletion createEmbedding )]}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Engine::Ollama> - Native Ollama API (with keep_alive, seed, context_size)

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format role composed by this engine

=item * L<https://github.com/ollama/ollama> - Ollama project

=back

=cut

1;
