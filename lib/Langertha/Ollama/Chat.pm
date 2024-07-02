package Langertha::Ollama::Chat;
# ABSTRACT: Ollama Chat chain

use Moose;
extends 'WWW::Chain';

use Carp qw( croak );

has ollama => (
  isa => 'Langertha::Ollama',
  is => 'ro',
  required => 1,
  handles => [qw(
    parse_response
  )],
);

has messages => (
  isa => 'Langertha::Messages',
  is => 'ro',
  lazy_build => 1,
);
sub _build_messages {
  my ( $self ) = @_;
  return $self->base_chat_messages($self->content);
}

has content => (
  isa => 'Str',
  is => 'ro',
  lazy_build => 1,
);
sub _build_content {
  my ( $self ) = @_;
  croak "".(ref $self)." requires content if no messages are given";
}

sub chat_request {
  my ( $self, $messages, %extra ) = @_;
  return $self->generate_request( generateChat =>
    model => $self->ollama->chat_model,
    messages => $messages->to_api,
    stream => JSON->false,
    $self->ollama->json_format ? ( format => 'json' ) : (),
    $self->ollama->has_keep_alive ? ( keep_alive => $self->ollama->keep_alive ) : (),
    %extra,
  );
}

sub chat_response {
  my ( $self, $response ) = @_;
  use DDP; p($response);
}

sub start_chain {
  my ( $self ) = @_;
  return $self->chat_request( $self->messages ), 'chat_response';
}

1;