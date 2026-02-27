package Langertha::Engine::AKIOpenAI;
# ABSTRACT: AKI.IO via OpenAI-compatible API
our $VERSION = '0.302';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAIBase';

with 'Langertha::Role::Tools';

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

Provides access to AKI.IO's OpenAI-compatible API at C<https://aki.io/v1>.
Composes L<Langertha::Role::OpenAICompatible> for the standard OpenAI format.

AKI.IO is a European AI model hub (Germany) — fully GDPR-compliant with all
inference on EU infrastructure. Supports chat completions (with SSE streaming),
MCP tool calling, and dynamic model listing.

Embeddings and transcription are not supported. For native AKI.IO API features
(C<top_k>, C<top_p>, C<max_gen_tokens>), use L<Langertha::Engine::AKI>.

Get your API key at L<https://aki.io/> and set C<LANGERTHA_AKI_API_KEY>.

B<THIS API IS WORK IN PROGRESS>

=cut

has '+url' => (
  lazy => 1,
  default => sub { 'https://aki.io/v1' },
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
