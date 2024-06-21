package Langertha::Role::Embedding;
# ABSTRACT: Role for APIs with embedding functionality

use Moose::Role;

requires qw( embedding_request );

has embedding_model => (
  is => 'ro',
  isa => 'Str',
  lazy_build => 1,
);
sub _build_embedding_model {
  my ( $self ) = @_;
  return $self->default_embedding_model if $self->can('default_embedding_model');
  return $self->default_model;
}

1;
