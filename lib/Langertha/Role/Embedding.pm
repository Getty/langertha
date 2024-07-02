package Langertha::Role::Embedding;
# ABSTRACT: Role for APIs with embedding functionality

use Moose::Role;
use Carp qw( croak );

requires qw( embedding );

has embedding_model => (
  is => 'ro',
  isa => 'Str',
  lazy_build => 1,
);
sub _build_embedding_model {
  my ( $self ) = @_;
  croak "".(ref $self)." can't handle models!" unless $self->does('Langertha::Role::Models');
  return $self->default_embedding_model if $self->can('default_embedding_model');
  return $self->default_model;
}

1;
