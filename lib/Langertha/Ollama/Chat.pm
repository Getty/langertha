package Langertha::Ollama::Chat;
# ABSTRACT: Ollama Chat chain

use Moose;
extends 'WWW::Chain';

use Carp qw( croak );
use JSON::MaybeXS;
use Langertha::Message;

has ollama => (
  isa => 'Langertha::Ollama',
  is => 'ro',
  required => 1,
  handles => [qw(
    chat_request
  )],
);

has messages => (
  isa => 'Langertha::Messages',
  is => 'ro',
  lazy_build => 1,
);
sub _build_messages {
  my ( $self ) = @_;
  return $self->ollama->base_chat_messages($self->content);
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

sub start_chain {
  my ( $self ) = @_;
  return $self->chat_request( $self->messages ), 'chat_response';
}

sub chat_response {
  my ( $self, $response ) = @_;
  my @response = $self->ollama->chat_response($response);
  return @response if $self->is_request($response[0]);
  if ($response[0]->{message}) {
    $self->messages->add_message(Langertha::Message->new($response[0]->{message}));
  }
  return;
}

1;