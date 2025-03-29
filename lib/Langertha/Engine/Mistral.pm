package Langertha::Engine::Mistral;
# ABSTRACT: Mistral API

use Moose;
extends 'Langertha::Engine::OpenAI';
use Carp qw( croak );

use File::ShareDir::ProjectDistDir qw( :all );

sub all_models {qw(
  codestral-2405
  codestral-2411-rc5
  codestral-2412
  codestral-2501
  codestral-latest
  codestral-mamba-2407
  codestral-mamba-latest
  ministral-3b-2410
  ministral-3b-latest
  ministral-8b-2410
  ministral-8b-latest
  mistral-embed
  mistral-large-2402
  mistral-large-2407
  mistral-large-2411
  mistral-large-latest
  mistral-large-pixtral-2411
  mistral-medium
  mistral-medium-2312
  mistral-medium-latest
  mistral-moderation-2411
  mistral-moderation-latest
  mistral-ocr-2503
  mistral-ocr-latest
  mistral-saba-2502
  mistral-saba-latest
  mistral-small
  mistral-small-2312
  mistral-small-2402
  mistral-small-2409
  mistral-small-2501
  mistral-small-2503
  mistral-small-latest
  mistral-tiny
  mistral-tiny-2312
  mistral-tiny-2407
  mistral-tiny-latest
  open-codestral-mamba
  open-mistral-7b
  open-mistral-nemo
  open-mistral-nemo-2407
  open-mixtral-8x22b
  open-mixtral-8x22b-2404
  open-mixtral-8x7b
  pixtral-12b
  pixtral-12b-2409
  pixtral-12b-latest
  pixtral-large-2411
  pixtral-large-latest
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

B<THIS API IS WORK IN PROGRESS>

=head1 HOW TO GET MISTRAL API KEY

L<https://docs.mistral.ai/getting-started/quickstart/>

=cut
