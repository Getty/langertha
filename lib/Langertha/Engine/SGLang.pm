package Langertha::Engine::SGLang;
# ABSTRACT: SGLang inference server
our $VERSION = '0.503';
use Moose;

extends 'Langertha::Engine::OpenAIBase';

with 'Langertha::Role::Tools',
     'Langertha::Role::Runtime::MetricsPoll',
     'Langertha::Role::RuntimeKnobs';

# SGLang's per-request runtime knobs: cache_salt, extra_key, priority,
# return_cached_tokens_details. Speculative decoding is a server-launch flag
# (--speculative-*), not a request knob — see Langertha::Runtime::Knobs.
sub _build_knob_wire_format { 'sglang' }

=head1 SYNOPSIS

    use Langertha::Engine::SGLang;

    # 1. Simple chat
    my $sglang = Langertha::Engine::SGLang->new(
        url   => 'http://localhost:30000/v1',
        model => 'Qwen/Qwen2.5-7B-Instruct',
    );

    print $sglang->simple_chat('Say something nice');

    # 2. Streaming
    $sglang->simple_chat_stream(sub {
        print shift->content;
    }, 'Write a haiku about Perl');

    # 3. MCP tool calling (requires a tool-call-parser-compatible model)
    use Future::AsyncAwait;

    my $sglang = Langertha::Engine::SGLang->new(
        url         => 'http://localhost:30000/v1',
        model       => 'Qwen/Qwen2.5-7B-Instruct',
        mcp_servers => [$mcp],
    );

    my $response = await $sglang->chat_with_tools_f('Add 7 and 15');

    # 4. Multimodal input (vision-capable models served by SGLang)
    use Langertha::Content::Image;

    my $img  = Langertha::Content::Image->from_url('https://example.com/cat.jpg');
    my $resp = await $sglang->simple_chat_f({
        role    => 'user',
        content => [ 'What is in this image?', $img ],
    });

    # 5. Prometheus /metrics scraping (Runtime::MetricsPoll)
    my $records = await $sglang->poll_metrics_f('sglang:');

=head1 DESCRIPTION

Adapter for SGLang's OpenAI-compatible endpoint.
SGLang is typically exposed as C</v1/chat/completions> with optional
tool-calling support depending on model/backend setup.

Extends L<Langertha::Engine::OpenAIBase> (which composes
L<Langertha::Role::OpenAICompatible>, L<Langertha::Role::OpenAPI>,
L<Langertha::Role::Models>, L<Langertha::Role::Temperature>,
L<Langertha::Role::ResponseSize>, L<Langertha::Role::SystemPrompt>,
L<Langertha::Role::ResponseFormat>, L<Langertha::Role::Streaming>,
L<Langertha::Role::Chat>, L<Langertha::Role::ReasoningEffort>, and
L<Langertha::Role::PromptCache>); SGLang itself additionally composes
L<Langertha::Role::Tools> (MCP tool calling) and
L<Langertha::Role::Runtime::MetricsPoll> (Prometheus C</metrics> scrape).

Supports chat, streaming, tool calling, structured output, multimodal
input, and Prometheus /metrics scraping. Embeddings and transcription are
not exposed on the OpenAI-compatible surface SGLang serves by default.

Only C<url> is required. Use the full C</v1> base URL.
No API key is required for local setups.

See L<https://docs.sglang.ai/> for installation and configuration details.

=cut

has '+url' => (
  required => 1,
);

sub default_model { 'default' }

# LANGERTHA_SGLANG_API_KEY is derived from the class name; a local server
# needs no key, a --api-key-protected `sglang.launch_server` does.
sub api_key_required { 0 }

sub _build_api_key {
  return $ENV{LANGERTHA_SGLANG_API_KEY};
}

sub _build_supported_operations {[qw(
  createChatCompletion
  createCompletion
)]}

__PACKAGE__->meta->make_immutable;

=head1 CAPABILITIES

Advertised flags (derived from composed roles via L<Langertha::Role::Capabilities>):

=over 4

=item * C<chat> — L<Langertha::Role::Chat>

=item * C<streaming> — L<Langertha::Role::Streaming>

=item * C<tools_native> + C<tool_choice_{auto,any,none,named}> — L<Langertha::Role::Tools>

=item * C<runtime_metrics> — L<Langertha::Role::Runtime::MetricsPoll>

=item * C<response_format_{json_object,json_schema}> — L<Langertha::Role::ResponseFormat>

=item * C<temperature> — L<Langertha::Role::Temperature>

=item * C<reasoning_effort> — L<Langertha::Role::ReasoningEffort>

=item * C<response_size>, C<system_prompt>, C<parallel_tool_use>, C<context_size>, C<seed>
— generation-parameter knobs the engine will honour

=back

=cut

=seealso

=over

=item * L<https://docs.sglang.ai/> - SGLang documentation

=item * L<Langertha::Engine::OpenAIBase> - Base class for OpenAI-compatible engines

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format role

=item * L<Langertha::Role::Tools> - MCP tool calling interface

=item * L<Langertha::Role::Runtime::MetricsPoll> - Prometheus /metrics scraper

=item * L<Langertha::Engine::vLLM> - Sister self-hosted OpenAI-compatible engine (also Embedding + MetricsPoll)

=item * L<Langertha::Engine::LlamaCpp> - Sister self-hosted OpenAI-compatible engine (also Embedding + MetricsPoll)

=back

=cut

1;
