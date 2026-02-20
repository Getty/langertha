package Langertha::Engine::Whisper;
# ABSTRACT: Whisper compatible transcription server
our $VERSION = '0.101';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAI';

sub default_transcription_model { '' }

has '+url' => (
  required => 1,
);

sub _build_api_key { 'whisper' }

sub _build_supported_operations {[qw(
  createTranscription
  createTranslation
)]}

1;

=head1 SYNOPSIS

  use Langertha::Engine::Whisper;

  my $whisper = Langertha::Engine::Whisper->new(
    url => $ENV{WHISPER_URL},
  );

  print($whisper->simple_transcription('recording.ogg'));

=head1 DESCRIPTION

B<THIS API IS WORK IN PROGRESS>

=head1 HOW TO INSTALL FASTER WHISPER

L<https://github.com/fedirz/faster-whisper-server>

=cut
