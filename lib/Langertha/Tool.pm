package Langertha::Tool;
# ABSTRACT: Generic tool with coderefs

use Moose;
use Carp qw( croak );

with qw(
  Langertha::Role::Tool
);

has tool_name => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has tool_function => (
  is => 'ro',
  isa => 'CodeRef',
  lazy_build => 1,
);
sub _build_tool_function {
  my ( $self ) = @_;
  croak __PACKAGE__." requires a tool_function";
}

has tool_description => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has tool_parameters => (
  is => 'ro',
  required => 1,
);

has tool_definition => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_tool_definition {
  my ( $self ) = @_;
  return {
    type => 'function',
    name => $self->tool_name,
    description => $self->tool_description,
  };
}

1;