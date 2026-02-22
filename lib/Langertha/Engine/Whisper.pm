package Langertha::Engine::Whisper;
# ABSTRACT: Whisper compatible transcription server
our $VERSION = '0.201';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAI';

=head1 SYNOPSIS

    use Langertha::Engine::Whisper;

    my $whisper = Langertha::Engine::Whisper->new(
        url => $ENV{WHISPER_URL},
    );

    print $whisper->simple_transcription('recording.ogg');

=head1 DESCRIPTION

Provides access to a self-hosted Whisper-compatible transcription server.
Extends L<Langertha::Engine::OpenAI> and supports the C<createTranscription>
and C<createTranslation> operations.

C<url> is required. The API key defaults to C<'whisper'>. The transcription
model defaults to an empty string so the server uses its built-in default.

See L<https://github.com/fedirz/faster-whisper-server> for a compatible
server implementation.

B<THIS API IS WORK IN PROGRESS>

=cut

sub default_transcription_model { '' }

has '+url' => (
  required => 1,
);

sub _build_api_key { 'whisper' }

sub _build_supported_operations {[qw(
  createTranscription
  createTranslation
)]}

=seealso

=over

=item * L<https://github.com/fedirz/faster-whisper-server> - faster-whisper-server

=item * L<Langertha::Engine::OpenAI> - Parent engine

=item * L<Langertha::Engine::Groq> - Groq's hosted Whisper transcription

=item * L<Langertha> - Main Langertha documentation

=back

=cut

1;
