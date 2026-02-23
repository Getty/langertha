package Langertha::Engine::vLLM;
# ABSTRACT: vLLM inference server
our $VERSION = '0.202';
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
  SystemPrompt
  Streaming
  Chat
));

with 'Langertha::Role::Tools';

=head1 SYNOPSIS

    use Langertha::Engine::vLLM;

    my $vllm = Langertha::Engine::vLLM->new(
        url          => $ENV{VLLM_URL},
        model        => $ENV{VLLM_MODEL},
        system_prompt => 'You are a helpful assistant',
    );

    print $vllm->simple_chat('Say something nice');

    # MCP tool calling (requires server started with tool-call-parser)
    use Future::AsyncAwait;

    my $vllm = Langertha::Engine::vLLM->new(
        url         => 'http://localhost:8000/v1',
        model       => 'Qwen/Qwen2.5-3B-Instruct',
        mcp_servers => [$mcp],
    );

    my $response = await $vllm->chat_with_tools_f('Add 7 and 15');

=head1 DESCRIPTION

Provides access to vLLM, a high-throughput inference engine for large
language models. Composes L<Langertha::Role::OpenAICompatible> since vLLM
exposes an OpenAI-compatible API.

Both C<url> and C<model> are required. The URL must include the C</v1>
path prefix (e.g., C<http://localhost:8000/v1>). The API key defaults to
C<'vllm'> since local vLLM instances typically don't require authentication.

MCP tool calling requires the vLLM server to be started with
C<--enable-auto-tool-choice> and C<--tool-call-parser> matching the model
(C<hermes> for Qwen2.5/Hermes, C<llama3> for Llama, C<mistral> for Mistral).

See L<https://docs.vllm.ai/> for installation and configuration details.

B<THIS API IS WORK IN PROGRESS>

=cut

has '+url' => (
  required => 1,
);

sub default_model { croak "".(ref $_[0])." requires a default_model" }

sub _build_api_key { 'vllm' }

sub _build_supported_operations {[qw(
  createChatCompletion
  createCompletion
)]}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://docs.vllm.ai/> - vLLM documentation

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format role

=item * L<Langertha::Role::Tools> - MCP tool calling interface

=item * L<Langertha::Engine::OllamaOpenAI> - Another self-hosted OpenAI-compatible engine

=back

=cut

1;
