package Langertha::Role::Tools;
# ABSTRACT: Role for APIs with tools

use Moose::Role;

requires qw( json );

has tools => (
  is => 'ro',
  isa => 'ArrayRef[Langertha::Role::Tool]',
  predicate => 'has_tools',
);

sub tools_call_hashref {
  my ( $self, %hash ) = @_;
  my $name = delete $hash{name};
  return unless $name and $hash{arguments} and length $hash{arguments}; 
  my %arguments = %{$self->json->decode(delete $hash{arguments})};
  return $self->tools_call($name, %arguments);
}

sub tools_call {
  my ( $self, $tool_name, %arguments ) = @_;
  return unless $tool_name;
  for my $tool (@{$self->tools}) {
    if ($tool->tool_name eq $tool_name) {
      return $tool->tool_call(%arguments);
    }
  }
  return;
}

1;
