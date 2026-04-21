package Langertha::Cost;
# ABSTRACT: Immutable value object for the monetary cost of a single LLM call
our $VERSION = '0.404';
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

__PACKAGE__->meta->make_immutable;
1;
