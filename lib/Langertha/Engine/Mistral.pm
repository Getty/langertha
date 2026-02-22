package Langertha::Engine::Mistral;
# ABSTRACT: Mistral API
our $VERSION = '0.101';
use Moose;
extends 'Langertha::Engine::OpenAI';
use Carp qw( croak );

use File::ShareDir::ProjectDistDir qw( :all );

=head1 SYNOPSIS

    use Langertha::Engine::Mistral;

    my $mistral = Langertha::Engine::Mistral->new(
        api_key      => $ENV{MISTRAL_API_KEY},
        model        => 'mistral-large-latest',
        system_prompt => 'You are a helpful assistant',
        temperature  => 0.5,
    );

    print $mistral->simple_chat('Say something nice');

    my $embedding = $mistral->embedding($content);

=head1 DESCRIPTION

Provides access to Mistral AI's models via their API. Extends
L<Langertha::Engine::OpenAI> with Mistral's endpoint
(C<https://api.mistral.ai>) and its OpenAPI spec.

Popular models: C<mistral-small-latest> (default, fast), C<mistral-large-latest>
(most capable, 675B parameters), C<codestral-latest> (code generation),
C<devstral-latest> (development workflows), C<pixtral-large-latest> (vision).
Supports chat and embeddings; transcription is not available.

Dynamic model listing via C<list_models()> is inherited from
L<Langertha::Engine::OpenAI>. Get your API key at
L<https://docs.mistral.ai/getting-started/quickstart/> and set
C<LANGERTHA_MISTRAL_API_KEY>.

B<THIS API IS WORK IN PROGRESS>

=cut

has '+url' => (
  lazy => 1,
  default => sub { 'https://api.mistral.ai' },
);
around has_url => sub { 1 };

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_MISTRAL_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_MISTRAL_API_KEY or api_key set";
}

sub openapi_file { yaml => dist_file('Langertha','mistral.yaml') };

sub default_model { 'mistral-small-latest' }

sub chat_operation_id { 'chat_completion_v1_chat_completions_post' }

sub embedding_operation_id { 'embeddings_v1_embeddings_post' }

sub transcription_request {
  croak "".(ref $_[0])." doesn't support transcription";
}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://mistral.ai/models> - Official Mistral models documentation

=item * L<Langertha::Engine::OpenAI> - Parent class

=item * L<Langertha> - Main Langertha documentation

=back

=cut

1;
