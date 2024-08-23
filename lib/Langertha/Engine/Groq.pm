package Langertha::Engine::Groq;
# ABSTRACT: GroqCloud API

use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAI';

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_GROQ_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_GROQ_API_KEY or api_key set";
}

has '+url' => (
  lazy => 1,
  default => sub { 'https://api.groq.com/openai/v1' },
);

sub default_model { croak "".(ref $_[0])." requires a default_model" }

sub default_transcription_model { 'whisper-large-v3' }

sub _build_supported_operations {[qw(
  createChatCompletion
  createTranscription
)]}

1;

=head1 SYNOPSIS

  use Langertha::Engine::Groq;

  my $groq = Langertha::Engine::Groq->new(
    api_key => $ENV{GROQ_API_KEY},
    model => $ENV{GROQ_MODEL},
    system_prompt => 'You are a helpful assistant',
  );

  print($groq->simple_chat('Say something nice'));

=head1 DESCRIPTION

B<THIS API IS WORK IN PROGRESS>

=head1 HOW TO GET GROQ API KEY

L<https://console.groq.com/keys>

=cut
