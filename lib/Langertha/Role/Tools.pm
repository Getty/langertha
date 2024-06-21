package Langertha::Role::Tools;
# ABSTRACT: Role for APIs with tools

use Moose::Role;

requires qw( json );

has tools => (
  is => 'ro',
  isa => 'ArrayRef',
  predicate => 'has_tools',
);

has tools_definition => (
  is => 'ro',
  isa => 'Str',
  lazy_build => 1,
);
sub _build_tools_definition {
  my ( $self ) = @_;
  return $self->json->pretty(1)->encode([
    map { $_->tool_definition } @{$self->tools}
  ]);
}

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
