package Langertha::Engine::Whisper;
# ABSTRACT: Whisper compatible transcription server
our $VERSION = '0.405';
use Moose;

extends 'Langertha::Engine::TranscriptionBase';

=head1 SYNOPSIS

    use Langertha::Engine::Whisper;

    my $whisper = Langertha::Engine::Whisper->new(
        url => $ENV{WHISPER_URL},
    );

    print $whisper->simple_transcription('recording.ogg');

=head1 DESCRIPTION

Provides access to a self-hosted Whisper-compatible transcription server.
Extends L<Langertha::Engine::TranscriptionBase> and supports the
C<createTranscription> and C<createTranslation> operations.

C<url> is required. The API key defaults to C<'whisper'>. The transcription
model defaults to an empty string so the server uses its built-in default.

See L<https://github.com/fedirz/faster-whisper-server> for a compatible
server implementation.

L<Langertha::Engine::OpenAI> exposes a C<whisper> attribute that returns a
L<Langertha::Engine::TranscriptionBase> bound to the OpenAI cloud (sharing
its C<api_key> and C<url>) — use that when you want OpenAI's hosted Whisper
endpoint without re-stating credentials.

B<THIS API IS WORK IN PROGRESS>

=cut

sub default_transcription_model { '' }

sub default_model { '' }

has '+url' => (
  required => 1,
);

sub _build_api_key { 'whisper' }

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://github.com/fedirz/faster-whisper-server> - faster-whisper-server

=item * L<Langertha::Engine::TranscriptionBase> - Parent base class

=item * L<Langertha::Engine::OpenAI> - Provides a C<whisper> handle reusing its credentials

=item * L<Langertha::Engine::Groq> - Groq's hosted Whisper transcription

=item * L<Langertha::Role::Transcription> - Transcription role

=back

=cut

1;
