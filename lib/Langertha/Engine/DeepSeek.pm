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
        model        => 'deepseek-v4-flash',
        system_prompt => 'You are a helpful assistant',
        temperature  => 0.5,
    );

    print $deepseek->simple_chat('Say something nice');

=head1 DESCRIPTION

Provides access to DeepSeek's models via their API. Composes
L<Langertha::Role::OpenAICompatible> with DeepSeek's endpoint
(C<https://api.deepseek.com>) and API key handling.

Available models: C<deepseek-v4-flash> (default, hybrid thinking /
non-thinking, 1M context) and C<deepseek-v4-pro>. The legacy compatibility
aliases C<deepseek-chat> and C<deepseek-reasoner> were retired on 2026-07-24 —
pin the explicit V4 ids instead; these are also what the C</models> endpoint
returns. Embeddings and transcription are not supported. Dynamic model
listing via C<list_models()>.

B<Reasoning effort:> C<deepseek-v4-flash> accepts C<low>, C<high> (server
default) and C<max>; C<deepseek-v4-pro> currently accepts only C<high> and
C<max> (C<low> is treated as C<high> server-side, so this engine drops it
rather than emitting a misleading value).

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

sub default_model { 'deepseek-v4-flash' }

# Reasoning effort diverges by DeepSeek model within the shared openai wire
# format: the current V4 line (deepseek-v4-*) takes a flat reasoning_effort
# string; the legacy V3.2 line used a thinking:{type:enabled} toggle instead.
# Match the V3.2 family by explicit prefix — anchored, so `deepseek-v3`,
# `deepseek-v3.2`, `deepseek-v3.2-exp` (etc.) hit the legacy toggle, and
# retired aliases / unknown future ids default to V4 (the safe current
# default). A bare `/v3/i` regex was rejected: it matched too widely and
# could collide with future V3.x / V3.x-y naming. (V3.2 mapping flagged for
# live re-verify.)
sub _is_deepseek_v3 {
  my ( $model ) = @_;
  return 0 unless defined $model && length $model;
  return 1 if $model eq 'deepseek-v3' || $model eq 'deepseek-v3.2';
  return 1 if $model =~ /\Adeepseek-v3(?:\.\d+)?(?:-[A-Za-z0-9._-]+)?\z/;
  return 0;
}

# Effort ladder per api-docs.deepseek.com/api/create-chat-completion
# (verified 2026-08-10): deepseek-v4-flash accepts low|high|max (server
# default high); deepseek-v4-pro — and, conservatively, unknown future V4
# ids — accepts only high|max, with low treated as high server-side. The
# engine drops low for non-flash models instead of emitting a value the
# server would silently remap.
sub reasoning_kwargs {
  my ( $self ) = @_;
  return () unless $self->has_reasoning_effort;
  my $model = $self->can('chat_model') ? ( $self->chat_model // '' ) : '';
  if ( _is_deepseek_v3($model) ) {
    return ( thinking => { type => 'enabled' } );
  }
  my $e = $self->reasoning_effort;
  return () if $e eq 'low' && $model ne 'deepseek-v4-flash';
  return () unless $e eq 'low' || $e eq 'high' || $e eq 'max';
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
