package Langertha::Tool;
# ABSTRACT: Generic tool with coderefs

use Moose;
use Carp qw( croak );

with qw(
  Langertha::Role::Tool
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

sub tool_call {
  my ( $self, %args ) = @_;
  return $self->tool_function->($self, %args);
}

1;