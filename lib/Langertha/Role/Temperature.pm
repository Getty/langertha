package Langertha::Role::Temperature;
# ABSTRACT: Role for an engine that can have a temperature setting
our $VERSION = '0.503';
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

Where the selected model does not take a temperature (or, on OpenAI reasoning
models, not while reasoning is active), a value other than C<1> is left off the
wire with a warning that names your call site. Set on the engine, it warns once
per engine instance; passed per request, on every request.

=cut

=seealso

=over

=item * L<Langertha::Role::Seed> - Seed for reproducible outputs

=item * L<Langertha::Role::ResponseSize> - Limit response token count

=back

=cut

1;