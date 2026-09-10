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
OpenAI-compatible endpoint at C<https://inference.hetzner.com/api/v1>.

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

The four models currently listed at C</api/v1/models>:

=over 4

=item * C<Qwen/Qwen3.6-35B-A3B-FP8> — C<default>. Apache 2.0. MoE 35B/3B.
262K context. Text + image input.

=item * C<DeepSeek-V4-Flash-0731> — MoE 304B/13B. 512K context. Text only.

=item * C<GLM-5.2-NVFP4> — MoE 744B/40B. 512K context. Text only.

=item * C<Kimi-K2.7-Code> — MoE 1T/32B. 262K context. Text + image input.

=back

B<Tool support caveat:> the Hetzner Inference docs do not confirm server-side
tool calling or structured output on the OpenAI-compatible endpoint, and the
platform is explicitly experimental. The engine composes L<Langertha::Role::Tools>
(so C<chat_with_tools_f> exists) and L<Langertha::Role::ResponseFormat>, but
C<engine_capabilities> B<clears> C<tools_native>, every C<tool_choice_*>,
C<parallel_tool_use> and both C<response_format_*> flags rather than advertise
capabilities that may silently no-op. If a live test confirms the gateway honors
them for the model you use, re-add them in the engine's
C<around engine_capabilities>.

B<No embeddings or transcription:> the Hetzner Inference endpoint exposes chat
completions + image processing only. L</embedding> and L</transcription> are
not composed on this engine.

Get your API key at L<https://inference.hetzner.com/> and set
C<LANGERTHA_HETZNER_API_KEY> in your environment.

=cut

=head1 REFRESHING THE MODEL CATALOG

To add or remove a model: edit C<_build_static_models> below, update the
L</MODELS> POD block to match, add a Changes entry, and run the offline
tests (C<t/48_hetzner.t>, C<t/00_load.t>). The live drift check in
C<t/88_live_hetzner.t> (karr #40) compares the hardcoded catalog against
L<https://inference.hetzner.com/api/v1/models> and warns on missing models.

=cut

sub _build_supported_operations {[qw(
  createChatCompletion
)]}

has '+url' => (
  lazy => 1,
  default => sub { 'https://inference.hetzner.com/api/v1' },
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

# Hetzner Inference documents neither tool calling nor structured output on its
# OpenAI-compatible endpoint, and the platform is explicitly experimental —
# "you should not use the platform for production environments"
# (docs.hetzner.com/general/company-and-policy/experiments/inference/, verified
# 2026-09-01). Only /v1/models, /v1/completions and /v1/chat/completions exist.
# The wire shape is OpenAI-compatible, so the role inventory grants the tool and
# response_format flags — but nothing confirms the gateway honors them, so clear
# them rather than advertise capabilities that may silently no-op. Re-add via
# this around once a live test confirms them.
around engine_capabilities => sub {
  my ( $orig, $self, @rest ) = @_;
  my $caps = $self->$orig(@rest);
  delete @{$caps}{ qw(
    tools_native
    tool_choice_auto tool_choice_any tool_choice_none tool_choice_named
    response_format_json_object response_format_json_schema
    parallel_tool_use
  ) };
  return $caps;
};

__PACKAGE__->meta->make_immutable;

=head1 CAPABILITIES

Advertised flags (derived from composed roles via L<Langertha::Role::Capabilities>):

=over 4

=item * C<chat> — L<Langertha::Role::Chat>

=item * C<streaming> — L<Langertha::Role::Streaming>

=item * C<temperature> — L<Langertha::Role::Temperature>

=item * C<response_size>, C<system_prompt>, C<context_size>, C<seed>
— generation-parameter knobs the engine will honour

=back

C<tools_native>, C<tool_choice_*>, C<parallel_tool_use> and
C<response_format_*> are B<not> advertised even though L<Langertha::Role::Tools>
and L<Langertha::Role::ResponseFormat> are composed — the engine clears them in
its C<around engine_capabilities> (see the tool-support caveat above). If a live
test confirms them, re-add them there.

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
