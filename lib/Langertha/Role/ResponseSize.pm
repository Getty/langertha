package Langertha::Role::ResponseSize;
# ABSTRACT: Role for an engine where you can specify the response size (in tokens)
our $VERSION = '0.202';
use Moose::Role;

has response_size => (
  isa => 'Int',
  is => 'ro',
  predicate => 'has_response_size',
);

=attr response_size

Maximum number of tokens to generate in the response. Optional. When not set,
the engine uses its own C<default_response_size> if available, or omits the
parameter from the request.

=cut

sub get_response_size {
  my ( $self ) = @_;
  return $self->response_size if $self->has_response_size;
  return $self->default_response_size if $self->can('default_response_size');
  return;
}

=method get_response_size

    my $size = $engine->get_response_size;

Returns the effective response size: the explicit C<response_size> if set,
otherwise the engine's C<default_response_size>, otherwise C<undef>.

=cut

=seealso

=over

=item * L<Langertha::Role::ContextSize> - Limit total context tokens

=item * L<Langertha::Role::Temperature> - Sampling temperature

=back

=cut

1;