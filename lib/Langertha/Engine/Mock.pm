package Langertha::Engine::Mock;
# ABSTRACT: Langertha::Engine::Virtual under the engine name Mock
our $VERSION = '0.505';
use Moose;

extends 'Langertha::Engine::Virtual';

=head1 SYNOPSIS

    use Langertha;
    use Langertha::Virtual::Rules qw( answer );

    my $engine = Langertha->new_engine( Mock =>
      rules    => [ 'Hello' => answer('Hi there!') ],
      fallback => answer('done'),
    );

    my $echo = Langertha::Engine::Mock->preset('echo');

=head1 DESCRIPTION

The engine name C<Mock> for L<Langertha::Engine::Virtual>: the same class
with nothing added or changed, so code that picks its engine by name (for
example C<< Langertha->new_engine('Mock', ...) >>) can ask for a mock.
Everything - the rules, the script mode, the presets, C<rules_file> and the
recording - is documented in L<Langertha::Engine::Virtual>. Its
L<preset|Langertha::Engine::Virtual/preset> builds a
C<Langertha::Engine::Mock>.

=cut

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Engine::Virtual> - The engine and its rule language

=item * L<Langertha::Virtual::Rules> - C<answer>, C<tool>, C<tools> and C<after>

=back

=cut

1;
