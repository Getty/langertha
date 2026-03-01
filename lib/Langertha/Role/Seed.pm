package Langertha::Role::Seed;
# ABSTRACT: Role for an engine that can set a seed
our $VERSION = '0.304';
use Moose::Role;
use Carp qw( croak );

has randomize_seed => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_randomize_seed { 0 }

=attr randomize_seed

When true, a random seed is generated for each request. Defaults to C<0>
(disabled). Useful when you want varied outputs without setting a fixed seed.

=cut

has seed => (
  is => 'ro',
  predicate => 'has_seed',
);

=attr seed

Fixed integer seed for reproducible outputs. Optional. When set, the engine
passes it to the API to make sampling deterministic. Use C<randomize_seed>
instead when you want a different random seed on each call.

=cut

sub random_seed {
  return sprintf("%u",rand(100_000_000));
}

=method random_seed

    my $seed = $engine->random_seed;

Returns a random unsigned integer suitable for use as a seed value.

=cut

=seealso

=over

=item * L<Langertha::Role::Temperature> - Sampling temperature

=item * L<Langertha::Engine::Ollama> - Engine that composes this role

=back

=cut

1;