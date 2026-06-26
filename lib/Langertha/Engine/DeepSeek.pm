package Langertha::Engine::DeepSeek;
# ABSTRACT: DeepSeek API
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAIBase';

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

Available models: C<deepseek-chat> (default, non-thinking) and
C<deepseek-reasoner> (thinking) are stable compatibility aliases that now
route to DeepSeek V4. The explicit ids C<deepseek-v4-flash> and
C<deepseek-v4-pro> can be pinned directly — these are what the C</models>
endpoint now returns. Embeddings and transcription are not supported.
Dynamic model listing via C<list_models()>.

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

# Reasoning effort diverges by DeepSeek model within the shared openai wire
# format: the current V4 line (deepseek-v4-*, plus the deepseek-chat /
# deepseek-reasoner aliases that now route to V4) takes a flat reasoning_effort
# string accepting high|max; the legacy V3.2 line used a thinking:{type:enabled}
# toggle instead. Sniff the model. (V3.2 mapping flagged for live re-verify.)
sub reasoning_kwargs {
  my ( $self ) = @_;
  return () unless $self->has_reasoning_effort;
  my $model = $self->chat_model // '';
  if ( $model =~ /v3/i ) {
    return ( thinking => { type => 'enabled' } );
  }
  my $e = $self->reasoning_effort;
  return () unless $e eq 'high' || $e eq 'max';
  return ( reasoning_effort => $e );
}

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
