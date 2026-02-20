package Langertha::Engine::Mistral;
# ABSTRACT: Mistral API
our $VERSION = '0.101';
use Moose;
extends 'Langertha::Engine::OpenAI';
use Carp qw( croak );

use File::ShareDir::ProjectDistDir qw( :all );

sub all_models {qw(
  codestral-2411-rc5
  codestral-2412
  codestral-2501
  codestral-2508
  codestral-embed
  codestral-embed-2505
  codestral-latest
  devstral-2512
  devstral-latest
  devstral-medium-2507
  devstral-medium-latest
  devstral-small-2507
  devstral-small-latest
  labs-devstral-small-2512
  labs-mistral-small-creative
  magistral-medium-2509
  magistral-medium-latest
  magistral-small-2509
  magistral-small-latest
  ministral-14b-2512
  ministral-14b-latest
  ministral-3b-2410
  ministral-3b-2512
  ministral-3b-latest
  ministral-8b-2410
  ministral-8b-2512
  ministral-8b-latest
  mistral-embed
  mistral-embed-2312
  mistral-large-2411
  mistral-large-2512
  mistral-large-latest
  mistral-large-pixtral-2411
  mistral-medium
  mistral-medium-2505
  mistral-medium-2508
  mistral-medium-latest
  mistral-moderation-2411
  mistral-moderation-latest
  mistral-ocr-2503
  mistral-ocr-2505
  mistral-ocr-2512
  mistral-ocr-latest
  mistral-small-2501
  mistral-small-2506
  mistral-small-latest
  mistral-tiny
  mistral-tiny-2312
  mistral-tiny-2407
  mistral-tiny-latest
  mistral-vibe-cli-latest
  open-mistral-7b
  open-mistral-nemo
  open-mistral-nemo-2407
  pixtral-12b
  pixtral-12b-2409
  pixtral-12b-latest
  pixtral-large-2411
  pixtral-large-latest
  voxtral-mini-2507
  voxtral-mini-latest
  voxtral-mini-transcribe-2507
  voxtral-small-2507
  voxtral-small-latest
)}

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
