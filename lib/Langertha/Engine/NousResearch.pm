package Langertha::Engine::NousResearch;
# ABSTRACT: Nous Research Inference API
our $VERSION = '0.101';
use Moose;
extends 'Langertha::Engine::OpenAI';
use Carp qw( croak );

=head1 SYNOPSIS

    use Langertha::Engine::NousResearch;

    my $nous = Langertha::Engine::NousResearch->new(
        api_key => $ENV{NOUSRESEARCH_API_KEY},
        model   => 'Hermes-3-Llama-3.1-70B',
    );

    print $nous->simple_chat('Explain the Hermes prompt format');

    # MCP tool calling (hermes_tools enabled by default)
    use Future::AsyncAwait;

    my $nous = Langertha::Engine::NousResearch->new(
        api_key     => $ENV{NOUSRESEARCH_API_KEY},
        model       => 'Hermes-3-Llama-3.1-70B',
        mcp_servers => [$mcp],
    );

    my $response = await $nous->chat_with_tools_f('Add 7 and 15');

=head1 DESCRIPTION

Provides access to Nous Research's inference API. Extends
L<Langertha::Engine::OpenAI> with Nous's endpoint
(C<https://inference-api.nousresearch.com/v1>) and Hermes tool calling.

Available models: C<Hermes-3-Llama-3.1-70B> (default), C<Hermes-3-Llama-3.1-405B>,
C<Hermes-4-70B>, C<Hermes-4-405B>, C<DeepHermes-3-Mistral-24B-Preview>.

C<hermes_tools> is enabled by default. Tool descriptions are injected into
the system prompt as C<< <tools> >> XML, and C<< <tool_call> >> tags are
parsed from the model output. No server-side tool calling support required.
See L<Langertha::Role::Tools> for customization options.

Get your API key at L<https://portal.nousresearch.com/> and set
C<LANGERTHA_NOUSRESEARCH_API_KEY>.

B<THIS API IS WORK IN PROGRESS>

=cut

sub _build_supported_operations {[qw(
  createChatCompletion
)]}

has '+url' => (
  lazy => 1,
  default => sub { 'https://inference-api.nousresearch.com/v1' },
);
around has_url => sub { 1 };

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_NOUSRESEARCH_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_NOUSRESEARCH_API_KEY or api_key set";
}

sub default_model { 'Hermes-3-Llama-3.1-70B' }

# Hermes models use <tool_call> XML tags for tool calling
has '+hermes_tools' => ( default => 1 );

sub embedding_request {
  croak "".(ref $_[0])." doesn't support embedding";
}

sub transcription_request {
  croak "".(ref $_[0])." doesn't support transcription";
}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://nousresearch.com/> - Nous Research homepage

=item * L<https://portal.nousresearch.com/api-docs> - API documentation

=item * L<Langertha::Role::Tools> - Tool calling with Hermes support

=item * L<Langertha::Engine::OpenAI> - Parent class

=item * L<Langertha> - Main Langertha documentation

=back

=cut

1;
