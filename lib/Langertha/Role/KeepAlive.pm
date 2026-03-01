package Langertha::Role::KeepAlive;
# ABSTRACT: Role for engines that support keep-alive duration
our $VERSION = '0.304';
use Moose::Role;

has keep_alive => (
  isa => 'Str',
  is => 'ro',
  predicate => 'has_keep_alive',
);

=attr keep_alive

    keep_alive => '5m'
    keep_alive => '-1'   # keep forever

Controls how long the engine keeps the model loaded in memory after a request.
Accepts duration strings such as C<5m> or C<-1> (keep forever). When not set,
the engine uses its own default.

See also C<no_keep_alive> for explicitly unloading the model after each request.

=cut

has no_keep_alive => (
  isa => 'Bool',
  is => 'ro',
  default => 0,
);

=attr no_keep_alive

    no_keep_alive => 1

When true, the model is unloaded from memory immediately after each request.
Equivalent to setting C<keep_alive =E<gt> '0'> but more explicit.

=cut

sub get_keep_alive {
  my ( $self ) = @_;
  return '0' if $self->no_keep_alive;
  return $self->keep_alive if $self->has_keep_alive;
  return undef;
}

=method get_keep_alive

Returns the effective keep-alive value: C<'0'> if C<no_keep_alive> is set,
the C<keep_alive> value if provided, or C<undef> if neither is set (letting
the engine use its default).

=cut

=seealso

=over

=item * L<Langertha::Engine::Ollama> - Engine that composes this role

=back

=cut

1;
