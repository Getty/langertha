package Langertha::Stream::Chunk;
# ABSTRACT: Represents a single chunk from a streaming response

use Moose;
use namespace::autoclean;

has content => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has raw => (
  is => 'ro',
  isa => 'HashRef',
  predicate => 'has_raw',
);

has is_final => (
  is => 'ro',
  isa => 'Bool',
  default => 0,
);

has model => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_model',
);

has finish_reason => (
  is => 'ro',
  isa => 'Maybe[Str]',
  predicate => 'has_finish_reason',
);

has usage => (
  is => 'ro',
  isa => 'Maybe[HashRef]',
  predicate => 'has_usage',
);

__PACKAGE__->meta->make_immutable;

1;
