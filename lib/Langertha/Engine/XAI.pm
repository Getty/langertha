package Langertha::Engine::XAI;
# ABSTRACT: xAI Grok API
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAIBase';

with 'Langertha::Role::Tools';

=head1 SYNOPSIS

    use Langertha::Engine::XAI;

    my $xai = Langertha::Engine::XAI->new(
        api_key       => $ENV{XAI_API_KEY},
        model         => 'grok-4.3',
        system_prompt => 'You are a helpful assistant',
    );

    print $xai->simple_chat('Say something nice');

    # Streaming
    $xai->simple_chat_stream(sub {
        print shift->content;
    }, 'Write a poem');

    # Tool calling
    my $response = await $xai->chat_with_tools_f('Search for Perl modules');

=head1 DESCRIPTION

Provides access to L<xAI|https://x.ai/>'s Grok models via their
OpenAI-compatible API at C<https://api.x.ai/v1>. Composes
L<Langertha::Role::OpenAICompatible> with xAI's endpoint and API key
handling, plus L<Langertha::Role::Tools> for MCP tool calling.

Grok 4.3 (C<grok-4.3>, the default) is xAI's flagship general model: a
1M-token context window, agentic tool calling, and vision input. The
coding-specialized C<grok-build-0.1> can be pinned via C<model>. Grok has no
knowledge of current events beyond its training cut-off unless you enable
xAI's server-side Web Search / X Search tools.

xAI's audio (Voice API) and image/video (Imagine API) live on separate
endpoints and are not exposed by this engine; it covers chat, streaming,
tool calling, and structured output.

Get your API key at L<https://console.x.ai/> and set
C<LANGERTHA_XAI_API_KEY> in your environment.

B<THIS API IS WORK IN PROGRESS>

=cut

sub _build_supported_operations {[qw(
  createChatCompletion
)]}

has '+url' => (
  lazy => 1,
  default => sub { 'https://api.x.ai/v1' },
);

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_XAI_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_XAI_API_KEY or api_key set";
}

sub default_model { 'grok-4.3' }

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://status.x.ai/> - xAI service status

=item * L<https://docs.x.ai/docs/models> - Official xAI models documentation

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format role

=item * L<Langertha::Role::Tools> - MCP tool calling interface

=item * L<Langertha::Engine::Groq> - Another OpenAI-compatible engine

=back

=cut

1;
