package Langertha::Role::Tool;
# ABSTRACT: Role for tools themselves

use Moose::Role;
use Carp qw( croak );

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
  lazy_build => 1,
);
sub _build_tool_parameters {
  my ( $self ) = @_;
  croak "".(ref $self)." needs tool parameters" unless $self->has_tool_parameters_descriptions;
  return {
    type => "object",
    properties => {
      map {
        $_ => {
          type => "string",
          description => $self->tool_parameters_descriptions->{$_},
        },
      } keys %{$self->tool_parameters_descriptions},
    },
    required => [keys %{$self->tool_parameters_descriptions}],
  };
}

has tool_parameters_descriptions => (
  is => 'ro',
  predicate => 'has_tool_parameters_descriptions',
);

has tool_definition => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_tool_definition {
  my ( $self ) = @_;
  return {
    type => 'function',
    function => {
      name => $self->tool_name,
      description => $self->tool_description,
      parameters => $self->tool_parameters,
    },
  };
}

1;
