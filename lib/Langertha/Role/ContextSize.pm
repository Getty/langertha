package Langertha::Role::ContextSize;
# ABSTRACT: Role for an engine where you can specify the context size (in tokens)
our $VERSION = '0.101';
use Moose::Role;

has context_size => (
  isa => 'Int',
  is => 'ro',
  predicate => 'has_context_size',
);

sub get_context_size {
  my ( $self ) = @_;
  return $self->context_size if $self->has_context_size;
  return $self->default_context_size if $self->can('default_context_size');
  return;
}

1;