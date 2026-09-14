package Langertha::Engine::Groq;
# ABSTRACT: GroqCloud API
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAIBase';

with map { 'Langertha::Role::'.$_ } qw(
  Transcription
  Tools
);

=head1 SYNOPSIS

    use Langertha::Engine::Groq;

    my $groq = Langertha::Engine::Groq->new(
        api_key      => $ENV{GROQ_API_KEY},
        model        => 'llama-3.3-70b-versatile',
        system_prompt => 'You are a helpful assistant',
    );

    print $groq->simple_chat('Say something nice');

    # Audio transcription
    my $text = $groq->transcription('/path/to/audio.mp3');

=head1 DESCRIPTION

Provides access to Groq's ultra-fast LLM inference via their GroqCloud API.
Composes L<Langertha::Role::OpenAICompatible> with Groq's endpoint
(C<https://api.groq.com/openai/v1>) and API key handling.

Popular models: C<llama-3.3-70b-versatile>, C<llama-3-groq-70b-tool-use>,
C<deepseek-r1-distill-llama-70b>, C<qwen-2.5-coder-32b>. Audio transcription
uses C<whisper-large-v3> by default. No default chat model is set; C<model>
must be specified explicitly.

Dynamic model listing via C<list_models()>. Get your API key at
L<https://console.groq.com/keys> and set C<LANGERTHA_GROQ_API_KEY>.

B<THIS API IS WORK IN PROGRESS>

=cut

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

# karr #142: Groq's Structured Outputs (response_format type json_schema) are
# mutually exclusive with both tool use and streaming, and its API rejects
# either combination with an opaque HTTP 400. json_object mode is a separate
# feature that IS allowed alongside tools, so this guard is mode-aware and only
# fires for json_schema. Consulted by Langertha::Role::Chat from chat_f
# (streaming => 0) and chat_stream_realtime_f (streaming => 1).
sub _check_capability_exclusions {
  my ( $self, %args ) = @_;
  my $rf   = $args{response_format};
  my $type = ( ref $rf eq 'HASH' ) ? ( $rf->{type} // '' ) : '';
  return unless $type eq 'json_schema';
  if ( $args{streaming} ) {
    croak "".(ref $self)." cannot combine response_format json_schema with "
      ."streaming: Groq Structured Outputs do not support streaming and the "
      ."API rejects this with HTTP 400. Use the non-streaming chat_f for "
      ."json_schema output.";
  }
  if ( $args{has_tools} ) {
    croak "".(ref $self)." cannot combine tools and response_format json_schema "
      ."in one request: Groq Structured Outputs do not support tool use and the "
      ."API rejects this with HTTP 400. Send tools or json_schema, not both "
      ."(json_object mode is allowed alongside tools).";
  }
  return;
}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://groqstatus.com/> - Groq service status

=item * L<https://console.groq.com/docs/models> - Official Groq models documentation

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format role

=item * L<Langertha::Role::Transcription> - Transcription role (Groq hosts Whisper)

=item * L<Langertha::Engine::DeepSeek> - Another OpenAI-compatible engine

=back

=cut

1;
