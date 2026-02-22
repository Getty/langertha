package Langertha::Engine::MiniMax;
# ABSTRACT: MiniMax API
our $VERSION = '0.201';
use Moose;
extends 'Langertha::Engine::OpenAI';
use Carp qw( croak );

=head1 SYNOPSIS

    use Langertha::Engine::MiniMax;

    my $minimax = Langertha::Engine::MiniMax->new(
        api_key => $ENV{MINIMAX_API_KEY},
        model   => 'MiniMax-M2.5',
    );

    print $minimax->simple_chat('Hello from Perl!');

    # Streaming
    $minimax->simple_chat_stream(sub {
        print shift->content;
    }, 'Write a poem');

    # Tool calling works out of the box
    my $response = await $minimax->chat_with_tools_f('Search for Perl modules');

=head1 DESCRIPTION

Provides access to L<MiniMax|https://www.minimax.io/> models via their
OpenAI-compatible API. Extends L<Langertha::Engine::OpenAI> with MiniMax's
endpoint (C<https://api.minimax.io/v1>) and API key handling.

MiniMax is a Chinese AI company based in Shanghai, offering large language
models with strong coding, reasoning, and agentic capabilities.

Available models: C<MiniMax-M2.5> (latest flagship), C<MiniMax-M2.5-highspeed>
(lower latency), C<MiniMax-M2.1>, C<MiniMax-M2.1-highspeed>, C<MiniMax-M2>.
Dynamic model listing via C<list_models()> is inherited.

Supports chat, streaming, and tool calling. Embeddings and transcription
are not supported.

Get your API key at L<https://platform.minimax.io/> and set
C<LANGERTHA_MINIMAX_API_KEY> in your environment.

B<THIS API IS WORK IN PROGRESS>

=cut

sub _build_supported_operations {[qw(
  createChatCompletion
)]}

has '+url' => (
  lazy => 1,
  default => sub { 'https://api.minimax.io/v1' },
);
around has_url => sub { 1 };

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_MINIMAX_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_MINIMAX_API_KEY or api_key set";
}

sub default_model { 'MiniMax-M2.5' }

sub embedding_request {
  croak "".(ref $_[0])." doesn't support embedding";
}

sub transcription_request {
  croak "".(ref $_[0])." doesn't support transcription";
}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://platform.minimax.io/docs/> - Official MiniMax API documentation

=item * L<Langertha::Engine::OpenAI> - Parent class

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format role

=item * L<Langertha::Engine::DeepSeek> - Another OpenAI-compatible engine

=back

=cut

1;
