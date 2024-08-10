package Langertha::Role::Temperature;
# ABSTRACT: Role for an engine that can have a temperature setting

use Moose::Role;

has temperature => (
  isa => 'Num',
  is => 'ro',
  predicate => 'has_temperature',
);

1;