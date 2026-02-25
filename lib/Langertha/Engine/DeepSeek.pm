package Langertha::Engine::DeepSeek;
# ABSTRACT: DeepSeek API
our $VERSION = '0.203';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAIBase';

with 'Langertha::Role::ResponseFormat';
with 'Langertha::Role::Tools';

=head1 SYNOPSIS

    use Langertha::Engine::DeepSeek;

    my $deepseek = Langertha::Engine::DeepSeek->new(
        api_key      => $ENV{DEEPSEEK_API_KEY},
        model        => 'deepseek-chat',
        system_prompt => 'You are a helpful assistant',
        temperature  => 0.5,
    );

    print $deepseek->simple_chat('Say something nice');

=head1 DESCRIPTION

Provides access to DeepSeek's models via their API. Composes
L<Langertha::Role::OpenAICompatible> with DeepSeek's endpoint
(C<https://api.deepseek.com>) and API key handling.

Available models: C<deepseek-chat> (default, general-purpose),
C<deepseek-reasoner> (chain-of-thought reasoning), and C<deepseek-v3.2>
(thinking integrated with tool use). Embeddings and transcription are not
supported. Dynamic model listing via C<list_models()>.

Get your API key at L<https://platform.deepseek.com/> and set
C<LANGERTHA_DEEPSEEK_API_KEY> in your environment.

B<THIS API IS WORK IN PROGRESS>

=cut

sub _build_supported_operations {[qw(
  createChatCompletion
)]}

has '+url' => (
  lazy => 1,
  default => sub { 'https://api.deepseek.com' },
);

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_DEEPSEEK_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_DEEPSEEK_API_KEY or api_key set";
}

sub default_model { 'deepseek-chat' }

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://status.deepseek.com/> - DeepSeek service status

=item * L<https://api-docs.deepseek.com/> - Official DeepSeek API documentation

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format role

=item * L<Langertha::Engine::Groq> - Another OpenAI-compatible engine

=back

=cut

1;
