package Langertha::Role::Runnable;
# ABSTRACT: Common async execution contract for Raider and Raid nodes
our $VERSION = '0.401';
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

Minimal execution contract shared by L<Langertha::Raider> and orchestration
nodes under L<Langertha::Raid>. Consumers must implement C<run_f($ctx)>.

=cut

requires 'run_f';

=method run_f

    my $result = await $node->run_f($ctx);

Required method. Executes the runnable node with a context and returns a
Future that resolves to a result object.

=cut

1;
