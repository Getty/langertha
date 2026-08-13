package Langertha::Cost;
# ABSTRACT: Immutable value object for the monetary cost of a single LLM call
our $VERSION = '0.503';
use Moose;

has input_usd  => ( is => 'ro', isa => 'Num', default => 0 );
has output_usd => ( is => 'ro', isa => 'Num', default => 0 );
has total_usd  => ( is => 'ro', isa => 'Num', lazy => 1, builder => '_build_total_usd' );
has currency   => ( is => 'ro', isa => 'Str', default => 'USD' );

sub _build_total_usd {
  my ($self) = @_;
  return $self->input_usd + $self->output_usd;
}

sub to_hash {
  my ($self) = @_;
  return {
    input_cost_usd  => $self->input_usd  + 0,
    output_cost_usd => $self->output_usd + 0,
    total_cost_usd  => $self->total_usd  + 0,
    currency        => $self->currency,
  };
}

# Make the object transparent to any JSON encoder configured with
# convert_blessed => 1 (the house default, see Langertha::Plugin::Langfuse).
# to_hash is the complete canonical representation, so this is a plain
# delegator — nothing is dropped.
sub TO_JSON { shift->to_hash }

__PACKAGE__->meta->make_immutable;
1;
