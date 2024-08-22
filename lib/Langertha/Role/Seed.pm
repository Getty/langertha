package Langertha::Role::Seed;
# ABSTRACT: Role for an engine that can set a seed

use Moose::Role;
use Carp qw( croak );

has randomize_seed => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_randomize_seed { 0 }

has seed => (
  is => 'ro',
  predicate => 'has_seed',
);

sub random_seed {
  return sprintf("%u",rand(100_000_000));
}

1;