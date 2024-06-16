package Langertha::Role::Tool;
# ABSTRACT: Role for tools themselves

use Moose::Role;

requires qw(
  tool_call
);

has tool_name => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

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
    parameters => $self->tool_parameters,
  };
}

1;
