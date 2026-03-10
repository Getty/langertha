package Langertha::Raid::Sequential;
# ABSTRACT: Sequential Raid orchestrator
our $VERSION = '0.307';
use Moose;
use Future::AsyncAwait;

extends 'Langertha::Raid';

=head1 SYNOPSIS

    my $raid = Langertha::Raid::Sequential->new(
      steps => [ $step1, $step2, $step3 ],
    );

    my $result = await $raid->run_f($ctx);

=head1 DESCRIPTION

Runs child steps in strict order and forwards one shared context through all
steps. Final outputs update context input for downstream steps. Non-final
results (question/pause/abort) are propagated immediately.

=cut

async sub run_f {
  my ( $self, $ctx ) = @_;
  $ctx = $self->_coerce_context($ctx);

  $ctx->add_trace({
    node  => ref($self),
    event => 'sequential_start',
    steps => scalar @{$self->steps},
  });

  return await $self->_run_steps_sequentially_f($ctx);
}

=method run_f

    my $result = await $raid->run_f($ctx);

Executes all steps sequentially with shared context propagation.

=cut

__PACKAGE__->meta->make_immutable;

1;
