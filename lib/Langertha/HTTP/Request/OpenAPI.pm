package Langertha::HTTP::Request::OpenAPI;
# ABSTRACT: HTTP Request inside of Langertha by OpenAPI modules

use Moose;
use MooseX::NonMoose;

extends 'HTTP::Request';

has args => (
  is => 'rw',
  isa => 'HashRef',
);

has openapi => (
  is => 'rw',
  does => 'Langertha::Role::OpenAPI',
);

has operation => (
  is => 'rw',
  isa => 'Str',
);

1;
