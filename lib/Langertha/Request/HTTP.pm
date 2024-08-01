package Langertha::Request::HTTP;

use Moose;
use MooseX::NonMoose;

extends 'HTTP::Request';

has request_source => (
  is => 'rw',
  does => 'Langertha::Role::HTTP',
);

has response_call => (
  is => 'rw',
  isa => 'CodeRef',
);

__PACKAGE__->meta->make_immutable;