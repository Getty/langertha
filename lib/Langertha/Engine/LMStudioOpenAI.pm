package Langertha::Engine::LMStudioOpenAI;
# ABSTRACT: LM Studio via OpenAI-compatible API
our $VERSION = '0.503';
use Moose;

extends 'Langertha::Engine::OpenAIBase';

with 'Langertha::Role::Embedding', 'Langertha::Role::Tools';

=head1 SYNOPSIS

    use Langertha::Engine::LMStudioOpenAI;

    # 1. Simple chat
    my $lm_oai = Langertha::Engine::LMStudioOpenAI->new(
        url   => 'http://localhost:1234/v1',
        model => 'qwen2.5-7b-instruct-1m',
    );

    print $lm_oai->simple_chat('Hello from OpenAI-compatible endpoint');

    # 2. Streaming
    $lm_oai->simple_chat_stream(sub {
        print shift->content;
    }, 'Write a haiku about Perl');

    # 3. Embeddings (LM Studio serves /v1/embeddings when an embedding
    #    model is loaded)
    my $vector = $lm_oai->simple_embedding('Some text to embed');

    # 4. MCP tool calling (LM Studio supports native tool calling via the
    #    OpenAI-compatible /v1 endpoint for compatible models)
    use Future::AsyncAwait;

    my $lm_oai = Langertha::Engine::LMStudioOpenAI->new(
        url         => 'http://localhost:1234/v1',
        model       => 'qwen2.5-7b-instruct-1m',
        mcp_servers => [$mcp],
    );

    my $response = await $lm_oai->chat_with_tools_f('Add 7 and 15');

=head1 DESCRIPTION

Adapter for LM Studio's OpenAI-compatible local endpoint
(C</v1/chat/completions>, C</v1/models>, C</v1/embeddings>).

Extends L<Langertha::Engine::OpenAIBase> (which composes
L<Langertha::Role::OpenAICompatible>, L<Langertha::Role::OpenAPI>,
L<Langertha::Role::Models>, L<Langertha::Role::Temperature>,
L<Langertha::Role::ResponseSize>, L<Langertha::Role::SystemPrompt>,
L<Langertha::Role::ResponseFormat>, L<Langertha::Role::Streaming>,
L<Langertha::Role::Chat>, L<Langertha::Role::ReasoningEffort>, and
L<Langertha::Role::PromptCache>); LMStudioOpenAI itself additionally
composes L<Langertha::Role::Embedding> (C</v1/embeddings>) and
L<Langertha::Role::Tools> (MCP tool calling).

Authentication is optional. If C<api_key> (or C<LANGERTHA_LMSTUDIO_API_KEY>)
is set, it is sent as a bearer token.

B<Runtime metrics:> LM Studio does not expose a Prometheus C</metrics>
endpoint, so L<Langertha::Role::Runtime::MetricsPoll> is intentionally
B<not> composed here. Sister engines that do (vLLM, SGLang, llama.cpp)
expose Prometheus text-format metrics at the server root.

=cut

has '+url' => (
  lazy => 1,
  default => sub { 'http://localhost:1234/v1' },
);

sub _build_api_key {
  return $ENV{LANGERTHA_LMSTUDIO_API_KEY} || 'lmstudio';
}

=attr api_key

Optional bearer token for LM Studio's OpenAI-compatible endpoint.
If not provided, reads from C<LANGERTHA_LMSTUDIO_API_KEY> and otherwise
defaults to C<lmstudio>.

=cut

sub default_model { 'default' }
sub default_embedding_model { 'default' }

# Shares the LM Studio key with the native engine (derivation would name the
# protocol variant); optional, the local server accepts the 'lmstudio' dummy.
sub api_key_env { 'LANGERTHA_LMSTUDIO_API_KEY' }
sub api_key_required { 0 }

=attr model

Chat model name. Defaults to C<default>. For real requests, set this to
an actually loaded LM Studio model key (for example
C<qwen2.5-7b-instruct-1m>).

=cut

sub _build_supported_operations {[qw(
  createChatCompletion
  createEmbedding
)]}

__PACKAGE__->meta->make_immutable;

=head1 CAPABILITIES

Advertised flags (derived from composed roles via L<Langertha::Role::Capabilities>):

=over 4

=item * C<chat> — L<Langertha::Role::Chat>

=item * C<streaming> — L<Langertha::Role::Streaming>

=item * C<tools_native> + C<tool_choice_{auto,any,none,named}> — L<Langertha::Role::Tools>

=item * C<embedding> — L<Langertha::Role::Embedding>

=item * C<response_format_{json_object,json_schema}> — L<Langertha::Role::ResponseFormat>

=item * C<temperature> — L<Langertha::Role::Temperature>

=item * C<response_size>, C<system_prompt>, C<parallel_tool_use>, C<context_size>, C<seed>
— generation-parameter knobs the engine will honour

=back

=cut

=seealso

=over

=item * L<Langertha::Engine::LMStudio> - Native LM Studio API

=item * L<Langertha::Engine::OpenAIBase> - Base class for OpenAI-compatible engines

=item * L<Langertha::Engine::vLLM> - Sister self-hosted OpenAI-compatible engine (also Embedding)

=item * L<Langertha::Engine::LlamaCpp> - Sister self-hosted OpenAI-compatible engine (also Embedding)

=back

=cut

1;
