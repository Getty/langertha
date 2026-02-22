package Langertha::Engine::Mistral;
# ABSTRACT: Mistral API
our $VERSION = '0.101';
use Moose;
extends 'Langertha::Engine::OpenAI';
use Carp qw( croak );

use File::ShareDir::ProjectDistDir qw( :all );

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

=head1 SYNOPSIS

  use Langertha::Engine::Mistral;

  my $mistral = Langertha::Engine::Mistral->new(
    api_key => $ENV{MISTRAL_API_KEY},
    model => 'mistral-large-latest',
    system_prompt => 'You are a helpful assistant',
    temperature => 0.5,
  );

  print($mistral->simple_chat('Say something nice'));

  my $embedding = $mistral->embedding($content);

=head1 DESCRIPTION

This module provides access to Mistral AI's models via their API.

B<Popular Models (February 2026):>

=over 4

=item * B<mistral-large-latest> - Points to Mistral Large 3, the most capable model (675B total parameters, 41B active). Best for complex reasoning, multimodal tasks, and agentic workflows with 256k context window.

=item * B<mistral-large-3> - Mistral Large 3, one of the best permissive open-weight models. 41B active and 675B total parameters. Excellent multilingual support.

=item * B<mistral-medium-latest> - Balanced performance for general tasks.

=item * B<mistral-small-latest> - Fast, cost-effective option (default).

=item * B<codestral-latest> - Specialized for code generation and completion.

=item * B<devstral-latest> - Optimized for development workflows.

=item * B<ministral-8b-latest> - Efficient small model (8B parameters).

=item * B<pixtral-large-latest> - Vision-capable multimodal model.

=item * B<voxtral-mini-latest> - Audio transcription with diarization support.

=back

The Mistral 3 family includes powerful dense models (3B, 8B, 14B) and Mistral Large 3,
offering state-of-the-art performance across reasoning, coding, and multilingual tasks.

B<Dynamic Model Listing:> Mistral inherits from L<Langertha::Engine::OpenAI>,
so it supports C<list_models()> for dynamic model discovery. See
L<Langertha::Engine::OpenAI> for documentation on model listing and caching.

B<THIS API IS WORK IN PROGRESS>

=head1 HOW TO GET MISTRAL API KEY

L<https://docs.mistral.ai/getting-started/quickstart/>

=head1 SEE ALSO

=over 4

=item * L<https://mistral.ai/models> - Official Mistral models documentation

=item * L<Langertha::Engine::OpenAI> - Parent class

=item * L<Langertha> - Main Langertha documentation

=back

=cut
