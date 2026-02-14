package Langertha::Engine::Groq;
# ABSTRACT: GroqCloud API

use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAI';

sub all_models {qw(
  allam-2-7b
  deepseek-r1-distill-llama-70b
  deepseek-r1-distill-qwen-32b
  distil-whisper-large-v3-en
  gemma2-9b-it
  llama-3.1-8b-instant
  llama-3.2-11b-vision-preview
  llama-3.2-1b-preview
  llama-3.2-3b-preview
  llama-3.2-90b-vision-preview
  llama-3.3-70b-specdec
  llama-3.3-70b-versatile
  llama-3-groq-70b-tool-use
  llama-3-groq-8b-tool-use
  llama-guard-3-8b
  llama3-70b-8192
  llama3-8b-8192
  llama-4-scout-17b-16e-instruct
  mistral-saba-24b
  playai-tts
  playai-tts-arabic
  qwen-2.5-32b
  qwen-2.5-coder-32b
  qwen-qwq-32b
  whisper-large-v3
  whisper-large-v3-turbo
)}

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
    model => 'llama-3.3-70b-versatile',
    system_prompt => 'You are a helpful assistant',
  );

  print($groq->simple_chat('Say something nice'));

  # Audio transcription
  my $text = $groq->transcription('/path/to/audio.mp3');

=head1 DESCRIPTION

This module provides access to Groq's ultra-fast LLM inference via their API.
Groq's LPU (Language Processing Unit) provides extremely fast inference speeds.

B<Popular Models (February 2026):>

=over 4

=item * B<llama-3.3-70b-versatile> - Meta's Llama 3.3 70B model. Excellent general-purpose model with strong reasoning capabilities.

=item * B<llama-3-groq-70b-tool-use> - Llama 3 optimized for tool use and function calling.

=item * B<deepseek-r1-distill-llama-70b> - DeepSeek R1 reasoning model distilled into Llama architecture. Best for complex reasoning tasks.

=item * B<qwen-2.5-coder-32b> - Qwen 2.5 specialized for coding tasks.

=item * B<llama-4-scout-17b-16e-instruct> - Meta's Llama 4 Scout vision model for image understanding.

=item * B<whisper-large-v3> - OpenAI Whisper for audio transcription (default transcription model).

=item * B<whisper-large-v3-turbo> - Faster Whisper variant for audio transcription.

=back

B<Features:>

=over 4

=item * Ultra-fast inference with Groq's LPU technology

=item * Chat completions

=item * Audio transcription (Whisper models)

=item * Tool use and function calling

=item * Vision models for image understanding

=item * Reasoning models with chain-of-thought

=item * Dynamic model discovery via API (inherited from OpenAI)

=back

B<Note:> Groq inherits from L<Langertha::Engine::OpenAI>, so it supports
C<list_models()> for dynamic model discovery. See L<Langertha::Engine::OpenAI>
for documentation on model listing, caching, and other features.

B<THIS API IS WORK IN PROGRESS>

=head1 HOW TO GET GROQ API KEY

L<https://console.groq.com/keys>

=head1 SEE ALSO

=over 4

=item * L<https://console.groq.com/docs/models> - Official Groq models documentation

=item * L<Langertha::Engine::OpenAI> - Parent class

=item * L<Langertha> - Main Langertha documentation

=back

=cut
