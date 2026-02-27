package Langertha::Role::ContextSize;
# ABSTRACT: Role for an engine where you can specify the context size (in tokens)
our $VERSION = '0.302';
use Moose::Role;

has context_size => (
  isa => 'Int',
  is => 'ro',
  predicate => 'has_context_size',
);

=attr context_size

The maximum context size in tokens to use for requests. Optional. When not set,
the engine uses its own C<default_context_size> if available, or omits the
parameter from the request.

=cut

sub get_context_size {
  my ( $self ) = @_;
  return $self->context_size if $self->has_context_size;
  return $self->default_context_size if $self->can('default_context_size');
  return;
}

=method get_context_size

    my $size = $engine->get_context_size;

Returns the effective context size: the explicit C<context_size> if set,
otherwise the engine's C<default_context_size>, otherwise C<undef>.

=cut

=seealso

=over

=item * L<Langertha::Role::ResponseSize> - Limit response token count

=item * L<Langertha::Engine::Ollama> - Engine that composes this role

=back

=cut

1;