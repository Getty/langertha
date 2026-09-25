package Langertha::Engine::OpenRouter;
# ABSTRACT: OpenRouter API
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAIBase';

with 'Langertha::Role::Tools';

=head1 SYNOPSIS

    use Langertha::Engine::OpenRouter;

    my $router = Langertha::Engine::OpenRouter->new(
        api_key => $ENV{OPENROUTER_API_KEY},
        model   => 'anthropic/claude-sonnet-4-6',
    );

    print $router->simple_chat('Hello from Perl!');

    # Access many providers through one API
    my $deepseek = Langertha::Engine::OpenRouter->new(
        api_key => $ENV{OPENROUTER_API_KEY},
        model   => 'deepseek/deepseek-r1',
    );

=head1 DESCRIPTION

Provides access to OpenRouter, a unified API gateway for 300+ models from
many providers (OpenAI, Anthropic, Google, Meta, Mistral, and more).
Composes L<Langertha::Role::OpenAICompatible> with OpenRouter's endpoint
(C<https://openrouter.ai/api/v1>).

Model names use C<provider/model> format (e.g., C<anthropic/claude-sonnet-4-6>,
C<openai/gpt-4o>, C<google/gemini-2.5-flash>). No default model is set;
C<model> must be specified explicitly.

Supports chat, streaming, and MCP tool calling. Embeddings and transcription
are not supported.

Get your API key at L<https://openrouter.ai/settings/keys> and set
C<LANGERTHA_OPENROUTER_API_KEY> in your environment.

B<THIS API IS WORK IN PROGRESS>

=cut

has '+url' => (
  lazy => 1,
  default => sub { 'https://openrouter.ai/api/v1' },
);

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_OPENROUTER_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_OPENROUTER_API_KEY or api_key set";
}

sub default_model { croak "".(ref $_[0])." requires model to be set" }

sub _build_supported_operations {[qw(
  createChatCompletion
)]}

# image_input (k266, ADR 0019): a gateway: the model behind it is unknown to
# the client, so no static claim. The catch-all is a layer-3 row, not a
# layer-2 delete, so a fact probed from /models (architecture.input_modalities)
# can answer per model (ADR 0032).
sub model_capability_corrections {
  return ( qr/\A/ => { image_input => 0 } );
}

sub model_metadata_format { 'openrouter' }
sub model_metadata_url    { $_[0]->url . $_[0]->list_models_path }

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://status.openrouter.ai/> - OpenRouter service status

=item * L<https://openrouter.ai/docs> - OpenRouter documentation

=item * L<https://openrouter.ai/models> - Browse available models

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format role

=back

=cut

1;
