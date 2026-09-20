package Langertha::Role::Runnable;
# ABSTRACT: Common async execution contract (run_f) for runnable nodes
our $VERSION = '0.503';
use Moose::Role;

=head1 SYNOPSIS

    package My::Runnable;
    use Moose;
    use Future::AsyncAwait;
    with 'Langertha::Role::Runnable';

    async sub run_f {
      my ( $self, $ctx ) = @_;
      ...
    }

=head1 DESCRIPTION

Minimal, dependency-free execution contract: consumers implement C<run_f($ctx)>
and return a Future. A generic core primitive with no coupling to any particular
runner — the Raider agent and the Raid orchestration nodes in the langertha-raider
distribution are consumers, but nothing here depends on them.

=cut

requires 'run_f';

=method run_f

    my $result = await $node->run_f($ctx);

Required method. Executes the runnable node with a context and returns a
Future that resolves to a result object.

=cut

1;
