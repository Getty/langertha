package Langertha::Engine::Moonshot;
# ABSTRACT: Moonshot AI Kimi API (OpenAI-compatible)
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAIBase';

with map { 'Langertha::Role::'.$_ } qw(
  StaticModels
  Tools
);

=head1 SYNOPSIS

    use Langertha::Engine::Moonshot;

    my $moonshot = Langertha::Engine::Moonshot->new(
        api_key => $ENV{MOONSHOT_API_KEY},
        model   => 'kimi-k2.6',
    );

    print $moonshot->simple_chat('Hello from Perl!');

    # Streaming
    $moonshot->simple_chat_stream(sub {
        print shift->content;
    }, 'Write a poem');

    # Tool calling
    my $response = await $moonshot->chat_with_tools_f('Search for Perl modules');

=head1 DESCRIPTION

Provides access to L<Moonshot AI|https://www.moonshot.ai/>'s Kimi models via
their native OpenAI-compatible endpoint at C<https://api.moonshot.ai/v1>.

Moonshot AI is a Beijing-based AI company; their Kimi models are natively
multimodal (text, image, and video input) with strong coding, reasoning, and
agentic capabilities and a 256K context window.

B<Why the OpenAI endpoint:> Moonshot also exposes an Anthropic-compatible
C</anthropic> endpoint; if you need the Anthropic wire format, use
L<Langertha::Engine::MoonshotAnthropic>. The native OpenAI-compatible endpoint
is the recommended default.

B<Available models:>

=over 4

=item * C<kimi-k2.6> — Latest flagship (default). Kimi's most intelligent and
versatile model: native multimodal architecture, thinking and non-thinking
modes, dialogue and Agent tasks. 256K context.

=item * C<kimi-k2.7-code> — Most capable coding model: more reliable
instruction following in long contexts and higher coding task success. 256K
context.

=item * C<kimi-k2.7-code-highspeed> — High-speed variant of C<kimi-k2.7-code>
(~180 tokens/s, up to ~260 tokens/s in short-context scenarios).

=item * C<kimi-k2.5> — Previous flagship multimodal model. 256K context.

=item * C<moonshot-v1-8k> / C<moonshot-v1-32k> / C<moonshot-v1-128k> — The
generation-model series; identical except for maximum context length.

=back

See L<https://platform.kimi.ai/docs/models> for the full model catalog.

B<Reasoning note:> on this OpenAI-compatible endpoint Kimi controls reasoning
via a Kimi-specific C<thinking> object (C<{ type =E<gt> 'enabled' }> /
C<{ type =E<gt> 'disabled' }>), not the OpenAI-wire C<reasoning_effort> field.
This engine therefore does not advertise or emit C<reasoning_effort>; use
L<Langertha::Engine::MoonshotAnthropic> for the Anthropic reasoning wire.

Supports chat, streaming, tool calling, and structured output. Embeddings,
transcription, and image generation are not supported via this endpoint.

Get your API key at L<https://platform.kimi.ai/> and set
C<LANGERTHA_MOONSHOT_API_KEY> in your environment.

=cut

sub _build_supported_operations {[qw(
  createChatCompletion
)]}

has '+url' => (
  lazy => 1,
  default => sub { 'https://api.moonshot.ai/v1' },
);

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_MOONSHOT_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_MOONSHOT_API_KEY or api_key set";
}

sub default_model { 'kimi-k2.6' }

sub default_response_size { 4096 }

sub _build_static_models {[
  { id => 'kimi-k2.6' },
  { id => 'kimi-k2.7-code' },
  { id => 'kimi-k2.7-code-highspeed' },
  { id => 'kimi-k2.5' },
  { id => 'moonshot-v1-8k' },
  { id => 'moonshot-v1-32k' },
  { id => 'moonshot-v1-128k' },
]}

# Kimi's OpenAI-compatible endpoint controls reasoning via a `thinking` object
# ({type:enabled|disabled}), not the openai-wire `reasoning_effort` field that
# ReasoningEffort would otherwise emit. Clear the capability and never emit the
# field on this endpoint. (Route reasoning via MoonshotAnthropic.)
around engine_capabilities => sub {
  my ( $orig, $self, @rest ) = @_;
  my $caps = $self->$orig(@rest);
  delete $caps->{reasoning_effort};
  return $caps;
};

sub reasoning_kwargs { () }

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Engine::MoonshotAnthropic> - Moonshot via Anthropic-compatible endpoint

=item * L<https://platform.kimi.ai/docs/api/overview> - Kimi OpenAI-compatible API docs

=item * L<Langertha::Engine::OpenAIBase> - Base class for OpenAI-compatible engines

=item * L<Langertha::Role::Tools> - MCP tool calling interface

=back

=cut

1;
