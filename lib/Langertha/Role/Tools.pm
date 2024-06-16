package Langertha::Role::Tools;
# ABSTRACT: Role for APIs with tools

use Moose::Role;

has tools => (
  is => 'ro',
  isa => 'ArrayRef[Langertha::Role::Tool]',
  predicate => 'has_tools',
);

1;
