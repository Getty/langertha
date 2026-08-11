package Langertha::Engine::Hetzner;
# ABSTRACT: Hetzner Inference API (OpenAI-compatible)
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAIBase';

with map { 'Langertha::Role::'.$_ } qw(
  StaticModels
  Tools
);

=head1 SYNOPSIS

    use Langertha::Engine::Hetzner;

    my $hetzner = Langertha::Engine::Hetzner->new(
        api_key => $ENV{LANGERTHA_HETZNER_API_KEY},
    );

    print $hetzner->simple_chat('Hello from Perl!');

    # Streaming
    $hetzner->simple_chat_stream(sub {
        print shift->content;
    }, 'Write a poem');

    # Vision (Qwen/Qwen3.6-35B-A3B-FP8 accepts image_url content parts)
    use Langertha::Content::Image;
    my $img = Langertha::Content::Image->from_url('https://example.com/cat.jpg');
    my $resp = await $hetzner->simple_chat_f({
        role    => 'user',
        content => [ 'What is in this image?', $img ],
    });

    # Tool calling
    my $response = await $hetzner->chat_with_tools_f('Search for Perl modules');

=head1 DESCRIPTION

Provides access to L<Hetzner Cloud|https://www.hetzner.com/>'s
L<Inference API|https://inference.hetzner.com/api/v1> via their
OpenAI-compatible endpoint at C<https://inference.hetzner.com/v1>.

Hetzner's Inference API is currently experimental and free of charge; rate
limits are 10M input / 200K output tokens per 60 seconds per API key (HTTP 429
when exceeded). Bearer-token authentication via
C<LANGERTHA_HETZNER_API_KEY>.

Supports chat, streaming, tool calling, structured output (OpenAI-compatible
C<response_format>), and image inputs (C<image_url> content parts) on the
vision-capable models. Embeddings and transcription are not available on this
endpoint.

=head1 DEFAULT MODEL

C<Qwen/Qwen3.6-35B-A3B-FP8> — the smallest MoE of the four currently-listed
Hetzner models (35B total / 3B activated), Apache 2.0, text + image input,
262K context window. Picked because it is distinct from the existing
L<Langertha::Engine::Moonshot> default (Kimi K3) and avoids overlap with the
two text-only giants on the catalog (DeepSeek-V4-Flash, GLM-5.2-NVFP4).

=head1 MODELS

The four models currently listed at C</v1/models>:

=over 4

=item * C<Qwen/Qwen3.6-35B-A3B-FP8> — C<default>. Apache 2.0. MoE 35B/3B.
262K context. Text + image input.

=item * C<DeepSeek-V4-Flash-0731> — MoE 304B/13B. 512K context. Text only.

=item * C<GLM-5.2-NVFP4> — MoE 744B/40B. 512K context. Text only.

=item * C<Kimi-K2.7-Code> — MoE 1T/32B. 262K context. Text + image input.

=back

B<Tool support caveat:> the Hetzner Inference docs do not explicitly confirm
server-side tool support on the OpenAI-compatible endpoint. The engine advertises
C<tools_native> via L<Langertha::Role::Tools> because the wire shape is
OpenAI-compatible, but the live test should verify the gateway actually accepts
the C<tools> array against the model you intend to use.

B<No embeddings or transcription:> the Hetzner Inference endpoint exposes chat
completions + image processing only. L</embedding> and L</transcription> are
not composed on this engine.

Get your API key at L<https://inference.hetzner.com/> and set
C<LANGERTHA_HETZNER_API_KEY> in your environment.

=cut

sub _build_supported_operations {[qw(
  createChatCompletion
)]}

has '+url' => (
  lazy => 1,
  default => sub { 'https://inference.hetzner.com/v1' },
);

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_HETZNER_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_HETZNER_API_KEY or api_key set";
}

sub default_model { 'Qwen/Qwen3.6-35B-A3B-FP8' }

sub default_response_size { 4096 }

sub _build_static_models {[
  { id => 'Qwen/Qwen3.6-35B-A3B-FP8' },
  { id => 'DeepSeek-V4-Flash-0731' },
  { id => 'GLM-5.2-NVFP4' },
  { id => 'Kimi-K2.7-Code' },
]}

__PACKAGE__->meta->make_immutable;

=head1 CAPABILITIES

Advertised flags (derived from composed roles via L<Langertha::Role::Capabilities>):

=over 4

=item * C<chat> — L<Langertha::Role::Chat>

=item * C<streaming> — L<Langertha::Role::Streaming>

=item * C<tools_native> + C<tool_choice_{auto,any,none,named}> — L<Langertha::Role::Tools>
(advertised but see tool-support caveat above)

=item * C<response_format_{json_object,json_schema}> — L<Langertha::Role::ResponseFormat>

=item * C<temperature> — L<Langertha::Role::Temperature>

=item * C<response_size>, C<system_prompt>, C<parallel_tool_use>, C<context_size>, C<seed>
— generation-parameter knobs the engine will honour

=back

Vision input is supported on the two multimodal models (Qwen/Qwen3.6-35B-A3B-FP8
and Kimi-K2.7-Code) via C<image_url> content parts; this is handled by
L<Langertha::Content::Image> and L<Langertha::Role::Chat>'s normalization — there
is no engine-level C<vision> flag.

=cut

=seealso

=over

=item * L<Langertha::Engine::Moonshot> - Another OpenAI-compatible cloud engine with multimodal support

=item * L<Langertha::Engine::XAI> - Another OpenAI-compatible cloud engine with vision + tool calling

=item * L<https://inference.hetzner.com/> - Hetzner Inference API

=item * L<Langertha::Engine::OpenAIBase> - Base class for OpenAI-compatible engines

=item * L<Langertha::Role::Tools> - MCP tool calling interface

=back

=cut

1;
