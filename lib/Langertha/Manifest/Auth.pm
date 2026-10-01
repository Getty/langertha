package Langertha::Manifest::Auth;
# ABSTRACT: One auth mechanism of a provider manifest (type only, never a secret)
our $VERSION = '0.504';
use Moose;
with 'Langertha::Manifest::Validation';

=head1 SYNOPSIS

    my $auth = Langertha::Manifest::Auth->new( id => 'api', type => 'api_key' );

=head1 DESCRIPTION

An auth entry of a L<Langertha::Manifest>. It names a B<mechanism> only. It
never holds a key, a secret path or an environment-variable name: which
local credential feeds the mechanism is the client's decision. The
header/query contract (C<Authorization: Bearer>, C<x-api-key>, C<?key=>, …)
belongs to the endpoint's dialect, not to this entry.

=cut

my @KNOWN_TYPES = qw( api_key );
my %KNOWN_TYPE  = map { $_ => 1 } @KNOWN_TYPES;

has id   => ( is => 'ro', isa => 'Str', required => 1 );
has type => ( is => 'ro', isa => 'Str', required => 1 );

=attr id

Local id, unique within the manifest; endpoints point at it with
C<auth_ref>.

=attr type

Mechanism token (see L</known_types>). A pattern-valid but unknown type is
accepted; L</is_known_type> tells a client whether it can serve it.

=cut

sub BUILD {
  my ($self) = @_;
  $self->_check_id( 'id', $self->id );
  $self->_check_token( 'type', $self->type );
  return;
}

sub known_types { return @KNOWN_TYPES }

=method known_types

The v1 auth-type vocabulary: C<api_key>.

=cut

sub is_known_type { return $KNOWN_TYPE{ $_[0]->type } ? 1 : 0 }

=method is_known_type

True when L</type> is in the v1 vocabulary.

=cut

sub from_hash {
  my ( $class, $data ) = @_;
  $class->_check_fields( $data, required => [qw( id type )] );
  return $class->new( map { $_ => $class->_string( $_, $data->{$_} ) } qw( id type ) );
}

=method from_hash

Builds an auth entry from its JSON object form, rejecting unknown and
forbidden fields (a key, token, secret path or env-var name is forbidden).

=cut

sub to_hash {
  my ($self) = @_;
  return { id => $self->id, type => $self->type };
}

=method to_hash

Returns the JSON object form.

=cut

sub TO_JSON { shift->to_hash }

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Manifest> - The provider manifest

=back

=cut

1;
