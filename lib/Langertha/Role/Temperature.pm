package Langertha::Role::Temperature;
# ABSTRACT: Role for an engine that can have a temperature setting
our $VERSION = '0.301';
use Moose::Role;

has temperature => (
  isa => 'Num',
  is => 'ro',
  predicate => 'has_temperature',
);

=attr temperature

Sampling temperature as a number. Higher values (e.g. C<0.9>) make output more
random; lower values (e.g. C<0.1>) make it more focused and deterministic. When
not set, the engine's API default is used.

=cut

=seealso

=over

=item * L<Langertha::Role::Seed> - Seed for reproducible outputs

=item * L<Langertha::Role::ResponseSize> - Limit response token count

=back

=cut

1;