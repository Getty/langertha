package Langertha::Request::HTTP;
# ABSTRACT: A HTTP Request inside of Langertha

use Moose;
use MooseX::NonMoose;

extends 'HTTP::Request';

has request_source => (
  is => 'ro',
  does => 'Langertha::Role::HTTP',
);

has response_call => (
  is => 'ro',
  isa => 'CodeRef',
);

sub FOREIGNBUILDARGS {
  my ( $class, %args ) = @_;
  return @{$args{http}};
}

sub BUILDARGS {
  my ( $class, %args ) = @_;
  delete $args{http};
  return { %args };
}

1;