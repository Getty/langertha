package Langertha::Request::HTTP;

use Moose;
use MooseX::NonMoose;

extends 'HTTP::Request';

has engine => (
  is => 'rw',
  does => 'Langertha::Role::HTTP',
);

has response_call => (
  is => 'rw',
  isa => 'CodeRef',
);

1;
