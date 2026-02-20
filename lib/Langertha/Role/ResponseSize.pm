package Langertha::Role::ResponseSize;
# ABSTRACT: Role for an engine where you can specify the response size (in tokens)
our $VERSION = '0.101';
use Moose::Role;

has response_size => (
  isa => 'Int',
  is => 'ro',
  predicate => 'has_response_size',
);

sub get_response_size {
  my ( $self ) = @_;
  return $self->response_size if $self->has_response_size;
  return $self->default_response_size if $self->can('default_response_size');
  return;
}

1;