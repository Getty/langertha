package Langertha::Role::ResponseFormat;
# ABSTRACT: Role for an engine where you can specify structured output

use Moose::Role;

has response_format => (
  isa => 'HashRef',
  is => 'ro',
  predicate => 'has_response_format',
);

1;