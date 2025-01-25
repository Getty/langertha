package Langertha::Engine::DeepSeek;
# ABSTRACT: DeepSeek API

use Moose;
extends 'Langertha::Engine::OpenAI';
use Carp qw( croak );

sub _build_supported_operations {[qw(
  createChatCompletion
)]}

sub all_models {qw(
  deepseek-chat
  deepseek-reasoner
)}

has '+url' => (
  lazy => 1,
  default => sub { 'https://api.deepseek.com' },
);
around has_url => sub { 1 };

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_DEEPSEEK_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_DEEPSEEK_API_KEY or api_key set";
}

sub default_model { 'deepseek-chat' }

sub embedding_request {
  croak "".(ref $_[0])." doesn't support embedding";
}

sub transcription_request {
  croak "".(ref $_[0])." doesn't support transcription";
}

__PACKAGE__->meta->make_immutable;

=head1 SYNOPSIS

  use Langertha::Engine::DeepSeek;

  my $deepseek = Langertha::Engine::DeepSeek->new(
    api_key => $ENV{DEEPSEEK_API_KEY},
    system_prompt => 'You are a helpful assistant',
    temperature => 0.5,
  );

  print($deepseek->simple_chat('Say something nice'));

=head1 DESCRIPTION

B<THIS API IS WORK IN PROGRESS>

=head1 HOW TO GET DEEPSEEK API KEY

L<https://platform.deepseek.com/>

=cut
