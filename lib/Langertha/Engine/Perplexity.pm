package Langertha::Engine::Perplexity;
# ABSTRACT: Perplexity Sonar API
our $VERSION = '0.101';
use Moose;
extends 'Langertha::Engine::OpenAI';
use Carp qw( croak );

sub _build_supported_operations {[qw(
  createChatCompletion
)]}

has '+url' => (
  lazy => 1,
  default => sub { 'https://api.perplexity.ai' },
);
around has_url => sub { 1 };

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_PERPLEXITY_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_PERPLEXITY_API_KEY or api_key set";
}

sub default_model { 'sonar' }

sub embedding_request {
  croak "".(ref $_[0])." doesn't support embedding";
}

sub transcription_request {
  croak "".(ref $_[0])." doesn't support transcription";
}

__PACKAGE__->meta->make_immutable;

=head1 SYNOPSIS

  use Langertha::Engine::Perplexity;

  my $perplexity = Langertha::Engine::Perplexity->new(
    api_key => $ENV{PERPLEXITY_API_KEY},
    model   => 'sonar-pro',
  );

  print $perplexity->simple_chat('What are the latest Perl releases?');

=head1 DESCRIPTION

This module provides access to Perplexity's Sonar API. Perplexity models
are search-augmented LLMs that can access real-time web information.

B<Available Models:>

=over 4

=item * B<sonar> - Fast, lightweight search model (default)

=item * B<sonar-pro> - Advanced search model with deeper analysis

=item * B<sonar-reasoning> - Search with chain-of-thought reasoning

=item * B<sonar-reasoning-pro> - Most capable reasoning and search model

=back

B<Note:> Perplexity responses include citations and search results alongside
the generated text. The API is OpenAI-compatible for chat completions.

B<THIS API IS WORK IN PROGRESS>

=head1 GETTING AN API KEY

L<https://www.perplexity.ai/settings/api>

Set the environment variable:

  export PERPLEXITY_API_KEY=your-key-here
  # Or use LANGERTHA_PERPLEXITY_API_KEY

=head1 SEE ALSO

=over 4

=item * L<https://docs.perplexity.ai/> - Official Perplexity API documentation

=item * L<Langertha::Engine::OpenAI> - Parent class

=item * L<Langertha> - Main Langertha documentation

=back

=cut
