package Langertha::Engine::LlamaCpp;
# ABSTRACT: llama.cpp server
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAIBase';

with 'Langertha::Role::Embedding',
     'Langertha::Role::Tools',
     'Langertha::Role::Runtime::MetricsPoll',
     'Langertha::Role::RuntimeKnobs';

# llama.cpp's per-request runtime knobs: cache_prompt, n_cache_reuse, id_slot.
# Speculative decoding is a server-launch flag (--spec-draft-*), not a request
# knob — see Langertha::Runtime::Knobs.
sub _build_knob_wire_format { 'llamacpp' }

=head1 SYNOPSIS

    use Langertha::Engine::LlamaCpp;

    my $llama = Langertha::Engine::LlamaCpp->new(
        url           => 'http://localhost:8080/v1',
        system_prompt => 'You are a helpful assistant',
    );

    print $llama->simple_chat('Hello!');

    my $embedding = $llama->simple_embedding('Some text');

=head1 DESCRIPTION

Provides access to llama.cpp's built-in HTTP server, which exposes an
OpenAI-compatible API. Composes L<Langertha::Role::OpenAICompatible>.

Only C<url> is required. The URL must include the C</v1> path prefix
(e.g., C<http://localhost:8080/v1>). Since llama.cpp serves exactly one
model (loaded at server startup), no model name or API key is needed.

Supports chat, streaming, embeddings, and MCP tool calling.

See L<https://github.com/ggml-org/llama.cpp/blob/master/examples/server/README.md>
for server setup.

B<THIS API IS WORK IN PROGRESS>

=cut

sub default_model { 'default' }
sub default_embedding_model { 'default' }

# LANGERTHA_LLAMACPP_API_KEY is derived from the class name; a local server
# needs no key, a --api-key-protected `llama-server` does.
sub api_key_required { 0 }

sub _build_api_key {
  return $ENV{LANGERTHA_LLAMACPP_API_KEY};
}

sub _build_supported_operations {[qw(
  createChatCompletion
  createEmbedding
)]}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://github.com/ggml-org/llama.cpp> - llama.cpp project

=item * L<Langertha::Engine::vLLM> - Another self-hosted OpenAI-compatible engine

=item * L<Langertha::Engine::OllamaOpenAI> - Ollama's OpenAI-compatible API

=back

=cut

1;
