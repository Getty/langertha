package Langertha::Role::ResponseFormat;
# ABSTRACT: Role for an engine where you can specify structured output
our $VERSION = '0.101';
use Moose::Role;

has response_format => (
  isa => 'HashRef',
  is => 'ro',
  predicate => 'has_response_format',
);

=attr response_format

A HashRef specifying the structured output format for the response. The exact
structure depends on the engine. For OpenAI-compatible engines this is typically
C<{ type => 'json_object' }> or a JSON Schema definition. Optional.

=cut

=seealso

=over

=item * L<Langertha> - Main Langertha documentation

=item * L<Langertha::Role::Chat> - Chat functionality that uses response format

=back

=cut

1;