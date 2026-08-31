package Langertha::Engine::AKIOpenAI;
# ABSTRACT: AKI.IO via OpenAI-compatible API
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAIBase';

with 'Langertha::Role::Tools', 'Langertha::Role::HermesTools';

sub _build_tool_wire_format { 'hermes' }

# AKI.IO ships the model's chain-of-thought under the bare `reasoning` key on
# the OpenAI-compatible message, while Role::OpenAICompatible::chat_response
# reads only the DeepSeek/Nous `reasoning_content` spelling. Lift AKI's spelling
# onto Response.thinking here — AKI-scoped, so the role shared by ~25 engines is
# not widened on one provider's quirk. -- karr k127
around 'chat_response' => sub {
  my ( $orig, $self, @args ) = @_;
  my $resp = $self->$orig(@args);
  return $resp if $resp->has_thinking;
  my $reasoning = eval { $resp->raw->{choices}[0]{message}{reasoning} };
  return $resp unless defined $reasoning && length $reasoning;
  return $resp->clone_with( thinking => $reasoning );
};

=head1 SYNOPSIS

    use Langertha::Engine::AKIOpenAI;

    # Direct construction (use /v1 model names, NOT native AKI names)
    my $aki = Langertha::Engine::AKIOpenAI->new(
        api_key => $ENV{AKI_API_KEY},
        model   => 'llama3-chat-8b',
    );

    print $aki->simple_chat('Hello!');

    # Streaming
    $aki->simple_chat_stream(sub {
        print shift->content;
    }, 'Tell me about Perl');

    # Via AKI's openai() method (uses default model)
    use Langertha::Engine::AKI;

    my $aki_native = Langertha::Engine::AKI->new(
        api_key => $ENV{AKI_API_KEY},
        model   => 'llama3_8b_chat',
    );
    my $oai = $aki_native->openai;  # warns: model not mapped, uses default
    print $oai->simple_chat('Hello via OpenAI format!');

=head1 DESCRIPTION

Provides access to AKI.IO's OpenAI-compatible API at C<https://aki.io/openai/v1>.
Composes L<Langertha::Role::OpenAICompatible> for the standard OpenAI format.

AKI.IO is a European AI model hub (Germany) — fully GDPR-compliant with all
inference on EU infrastructure. Supports chat completions (with SSE streaming)
and dynamic model listing. Composes L<Langertha::Role::HermesTools> for MCP
tool calling via XML tags (AKI's C</openai/v1> endpoint does not support native
tool parameters).

Embeddings and transcription are not supported. For native AKI.IO API features
(C<top_k>, C<top_p>, C<max_gen_tokens>), use L<Langertha::Engine::AKI>.

B<Chain-of-thought:> AKI.IO returns the model's reasoning under the bare
C<reasoning> key on the message, not the C<reasoning_content> spelling the
shared OpenAI-compatible path reads. This engine lifts that key onto
L<Langertha::Response/thinking>, so C<< $response->thinking >> is populated.

B<Client errors arrive as HTTP 529:> AKI.IO returns some B<caller-side> errors
as C<529> C<overloaded_error> — notably a token budget too small to finish a
tool call (C<"Response finished before tool_call was completed! Try to raise
max_gen_tokens">). That condition is deterministic and fixed by raising
C<response_size> / C<max_tokens>, B<not> transient server overload: do not treat
an AKI C<529> as a wait-and-retry signal, and read
C<< $error->{error}{message} >> for the real diagnostic.

Get your API key at L<https://aki.io/> and set C<LANGERTHA_AKI_API_KEY>.

B<THIS API IS WORK IN PROGRESS>

=cut

# AKI.IO's OpenAI-compatibility docs are internally inconsistent about the base
# path: prose mentions /v1, but every working example (curl, Python SDK,
# machine-readable config, /models discovery) uses /openai/v1. We follow the
# working examples. See https://aki.io/docs/compatibility/openai-api-compatibility/
has '+url' => (
  lazy => 1,
  default => sub { 'https://aki.io/openai/v1' },
);

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_AKI_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_AKI_API_KEY or api_key set";
}

=attr api_key

The AKI.IO API key. If not provided, reads from C<LANGERTHA_AKI_API_KEY>
environment variable. Sent as a Bearer token in the C<Authorization> HTTP
header. Required.

=cut

sub default_model { 'llama3-chat-8b' }

sub api_key_env { 'LANGERTHA_AKI_API_KEY' }

sub _build_supported_operations {[qw( createChatCompletion )]}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Engine::AKI> - Native AKI.IO API (with top_k, top_p, max_gen_tokens)

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format role composed by this engine

=item * L<https://aki.io/docs> - AKI.IO API documentation

=back

=cut

1;
