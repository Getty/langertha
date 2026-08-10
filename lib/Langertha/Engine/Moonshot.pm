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
        model   => 'kimi-k3',
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
agentic capabilities. C<kimi-k3> offers a 1M-token context window; the K2.x
legacy models below remain at 256K.

B<Why the OpenAI endpoint:> Moonshot also exposes an Anthropic-compatible
C</anthropic> endpoint; if you need the Anthropic wire format, use
L<Langertha::Engine::MoonshotAnthropic>. The native OpenAI-compatible endpoint
is the recommended default.

B<Available models:>

=over 4

=item * C<kimi-k3> — Current flagship (default). Kimi's most capable model:
2.8 trillion parameters, native visual understanding, 1M context, frontier
reasoning and agentic tasks.

=item * C<kimi-k2.7-code> — Dedicated coding model: more reliable
instruction following in long contexts and higher coding task success. 256K
context.

=item * C<kimi-k2.7-code-highspeed> — High-speed variant of C<kimi-k2.7-code>
(~180 tokens/s, up to ~260 tokens/s in short-context scenarios).

=item * C<kimi-k2.6> — Previous multimodal model: thinking and non-thinking
modes, dialogue and Agent tasks. 256K context.

=back

B<Sunset:> C<kimi-k2.5> and the C<moonshot-v1-*> generation series are no
longer available to newly registered users and reach full platform sunset on
2026-08-31; they are deliberately no longer listed here. The older C<kimi-k2>
preview series was discontinued on 2026-05-25.

See L<https://platform.kimi.ai/docs/models> for the full model catalog.

B<Reasoning note:> reasoning control differs per model family on this
endpoint. The K2.x line uses a Kimi-specific C<thinking> object
(C<{ type =E<gt> 'enabled' }> / C<{ type =E<gt> 'disabled' }>), not the
OpenAI-wire C<reasoning_effort> field. C<kimi-k3> instead accepts a top-level
C<reasoning_effort> of C<low> / C<high> / C<max> and defaults to C<max>
server-side when the field is omitted. This engine does not advertise or emit
C<reasoning_effort> (K2.x compatibility); on C<kimi-k3> the server-side
default of C<max> therefore applies.

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

sub default_model { 'kimi-k3' }

sub default_response_size { 4096 }

sub _build_static_models {[
  { id => 'kimi-k3' },
  { id => 'kimi-k2.7-code' },
  { id => 'kimi-k2.7-code-highspeed' },
  { id => 'kimi-k2.6' },
]}

# Kimi's OpenAI-compatible endpoint controls reasoning per model family: the
# K2.x line uses a `thinking` object ({type:enabled|disabled}); kimi-k3 takes
# a top-level reasoning_effort (low|high|max, server-side default max). This
# engine clears the capability and never emits a reasoning field — on kimi-k3
# the server-side default of max then applies. (Wire-level reasoning via
# MoonshotAnthropic for the Anthropic dialect.)
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
