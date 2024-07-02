package Langertha::Role::Chat;
# ABSTRACT: Role for APIs with normal chat functionality

use Moose::Role;
use Carp qw( croak );

use Langertha::Message;
use Langertha::Messages;

requires qw( chat );

has chat_model => (
  is => 'ro',
  isa => 'Str',
  lazy_build => 1,
);
sub _build_chat_model {
  my ( $self ) = @_;
  croak "".(ref $self)." can't handle models!" unless $self->does('Langertha::Role::Models');
  return $self->default_chat_model if $self->can('default_chat_model');
  return $self->default_model;
}

sub base_chat_messages {
  my ( $self, $user_message, %extra ) = @_;
  return Langertha::Messages->new( messages => [
    $self->has_system_prompt ? (Langertha::Message->new(
      role => "system",
      content => $self->system_prompt,
    )) : (), 
    $user_message ? (Langertha::Message->new(
      role => 'user',
      content => $user_message,
      scalar %extra ? ( extra => { %extra } ) : (),
    )) : (),
  ]);
}

1;
