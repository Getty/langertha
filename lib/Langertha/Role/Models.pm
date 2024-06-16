package Langertha::Role::Models;
# ABSTRACT: Role for APIs with several models

use Moose::Role;

requires qw( default_model );

has models => (
  is => 'ro',
  isa => 'ArrayRef[Str]',
  lazy_build => 1,
);
sub _build_models {
  my ( $self ) = @_;
  return [$self->default_model];
}

has model => (
  is => 'ro',
  isa => 'Str',
  lazy_build => 1,
);
sub _build_model {
  my ( $self ) = @_;
  return $self->default_model;
}

1;
