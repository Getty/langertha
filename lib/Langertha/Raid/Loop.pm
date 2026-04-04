package Langertha::Raid::Loop;
# ABSTRACT: Looping Raid orchestrator
our $VERSION = '0.309';
use Moose;
use Future::AsyncAwait;
use Carp qw( croak );

use Langertha::Result;

extends 'Langertha::Raid';

=head1 SYNOPSIS

    my $raid = Langertha::Raid::Loop->new(
      steps     => [ $worker ],
      max_loops => 3,
    );

    my $result = await $raid->run_f($ctx);

=head1 DESCRIPTION

Repeats child step execution on orchestration level (not Raider's internal
tool loop). The loop stops when:

=over 4

=item * C<max_loops>/C<max_iterations> is reached

=item * a step returns C<question>, C<pause>, or C<abort>

=item * optional C<continue_while> callback returns false

=back

=cut

has max_loops => (
  is      => 'ro',
  isa     => 'Int',
  default => 1,
);

=attr max_loops

Maximum number of loop iterations (default limit).

=cut

has max_iterations => (
  is        => 'ro',
  isa       => 'Int',
  predicate => 'has_max_iterations',
);

=attr max_iterations

Alias/override for C<max_loops> when explicitly provided.

=cut

has continue_while => (
  is        => 'ro',
  isa       => 'CodeRef',
  predicate => 'has_continue_while',
);

=attr continue_while

Optional callback C<< sub ($ctx, $iteration, $result) >> controlling whether
the loop should continue after each final iteration.

=cut

sub BUILD {
  my ( $self ) = @_;
  croak "Loop requires max_loops/max_iterations >= 1"
    if $self->_loop_limit < 1;
}

sub _loop_limit {
  my ( $self ) = @_;
  return $self->has_max_iterations ? $self->max_iterations : $self->max_loops;
}

async sub run_f {
  my ( $self, $ctx ) = @_;
  $ctx = $self->_coerce_context($ctx);

  my $limit = $self->_loop_limit;
  my $last = Langertha::Result->final($ctx->input // '');

  $ctx->add_trace({
    node      => ref($self),
    event     => 'loop_start',
    max_loops => $limit,
  });

  for my $iteration (1..$limit) {
    $ctx->state->{loop_iteration} = $iteration;
    $ctx->add_trace({
      node      => ref($self),
      event     => 'loop_iteration_start',
      iteration => $iteration,
    });

    my $result = await $self->_run_steps_sequentially_f(
      $ctx,
      loop_iteration => $iteration,
    );

    if (!$result->is_final) {
      $ctx->metadata->{loop_iterations} = $iteration;
      return $self->_with_context_result($result, $ctx);
    }

    $last = $result;

    if ($self->has_continue_while) {
      my $continue = $self->continue_while->($ctx, $iteration, $result);
      last unless $continue;
    }
  }

  $ctx->metadata->{loop_iterations} = $ctx->state->{loop_iteration} // 0;
  return $self->_with_context_result($last, $ctx);
}

=method run_f

    my $result = await $raid->run_f($ctx);

Executes loop iterations with explicit iteration state and safe stop rules.

=cut

__PACKAGE__->meta->make_immutable;

1;
