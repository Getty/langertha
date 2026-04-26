package Langertha::Engine::LMStudioOpenAI;
# ABSTRACT: LM Studio via OpenAI-compatible API
our $VERSION = '0.501';
use Moose;

extends 'Langertha::Engine::OpenAIBase';

with 'Langertha::Role::Embedding', 'Langertha::Role::Tools';

=head1 SYNOPSIS

    use Langertha::Engine::LMStudioOpenAI;

    my $lm_oai = Langertha::Engine::LMStudioOpenAI->new(
        url   => 'http://localhost:1234/v1',
        model => 'qwen2.5-7b-instruct-1m',
    );

    print $lm_oai->simple_chat('Hello from OpenAI-compatible endpoint');

=head1 DESCRIPTION

Adapter for LM Studio's OpenAI-compatible local endpoint
(C</v1/chat/completions>, C</v1/models>, C</v1/embeddings>).

Authentication is optional. If C<api_key> (or C<LANGERTHA_LMSTUDIO_API_KEY>)
is set, it is sent as a bearer token.

B<THIS API IS WORK IN PROGRESS>

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

=seealso

=over

=item * L<Langertha::Engine::LMStudio> - Native LM Studio API

=item * L<Langertha::Engine::OpenAIBase> - Base class for OpenAI-compatible engines

=back

=cut

1;
