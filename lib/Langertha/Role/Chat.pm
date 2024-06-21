package Langertha::Role::Chat;
# ABSTRACT: Role for APIs with normal chat functionality

use Moose::Role;

requires qw( chat_request );

has chat_model => (
  is => 'ro',
  isa => 'Str',
  lazy_build => 1,
);
sub _build_chat_model {
  my ( $self ) = @_;
  return $self->default_chat_model if $self->can('default_chat_model');
  return $self->default_model;
}

1;
