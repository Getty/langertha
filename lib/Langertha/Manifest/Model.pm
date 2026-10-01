package Langertha::Manifest::Model;
# ABSTRACT: One model entry of a provider manifest: id, endpoint, declared capabilities
our $VERSION = '0.504';
use Moose;
use JSON::MaybeXS ();
with 'Langertha::Manifest::Validation';

=head1 SYNOPSIS

    my $model = Langertha::Manifest::Model->new(
      id           => 'gpt-5.6',
      endpoint_ref => 'chat',
      capabilities => { chat => 1, streaming => 1, tools_native => 1 },
    );

    $model->supports('tools_native');   # 1

=head1 DESCRIPTION

A model entry of a L<Langertha::Manifest>. The same model id may appear
once per endpoint (a proxy serves one model on several protocol endpoints),
so C<(id, endpoint_ref)> is the uniqueness key.

C<capabilities> are what the B<provider claims>, in the
L<Langertha::Role::Capabilities> vocabulary (C<engine_capabilities> names).
A claim is not a probe result and not a local permission.

=cut

has id           => ( is => 'ro', isa => 'Str', required => 1 );
has endpoint_ref => ( is => 'ro', isa => 'Str', required => 1 );
has capabilities => ( is => 'ro', isa => 'HashRef', default => sub { {} } );

=attr id

The model id as the endpoint expects it (free-form, e.g. C<org/model:tag>);
non-empty, no control characters, at most 256 characters.

=attr endpoint_ref

Id of the L<Langertha::Manifest::Endpoint> serving this model.

=attr capabilities

HashRef of capability name to C<1>/C<0>. Names match C<[a-z][a-z0-9_]*>;
input values may be JSON booleans, C<\1>/C<\0> or the numbers C<1>/C<0>
and are normalized to C<1>/C<0>; strings (C<"1">, C<"true">) are rejected.
Names are open: a client treats a capability it does not know as absent.

=cut

around BUILDARGS => sub {
  my ( $orig, $class, @args ) = @_;
  my $args = $class->$orig(@args);
  if ( exists $args->{capabilities} ) {
    my $caps = $args->{capabilities};
    $class->_error('capabilities: must be a JSON object') unless ref $caps eq 'HASH';
    my %norm;
    for my $name ( sort keys %$caps ) {
      $class->_error( "capabilities: invalid capability name '" . $class->_display($name) . q{'} )
        unless $name =~ /\A[a-z][a-z0-9_]{0,63}\z/;
      $norm{$name} = $class->_bool( "capabilities: '$name'", $caps->{$name} );
    }
    $args->{capabilities} = \%norm;
  }
  return $args;
};

sub BUILD {
  my ($self) = @_;
  my $id = $self->id;
  # Control, format (bidi overrides such as U+202E), surrogate, private-use,
  # unassigned and line/paragraph-separator characters are rejected: a client
  # prints model ids.
  $self->_error('id must be a non-empty model id without control or format characters (max 256)')
    unless length $id && length $id <= 256 && $id !~ /[\p{C}\p{Zl}\p{Zp}]/;
  $self->_check_id( 'endpoint_ref', $self->endpoint_ref );
  return;
}

sub supports {
  my ( $self, $cap ) = @_;
  return $self->capabilities->{$cap} ? 1 : 0;
}

=method supports

    $model->supports('streaming');

True when the manifest claims the capability for this model. Accepts any
name; an unknown or absent capability is simply not supported.

=cut

sub from_hash {
  my ( $class, $data ) = @_;
  $class->_check_fields( $data,
    required => [qw( id endpoint_ref )],
    optional => [qw( capabilities )],
  );
  return $class->new(
    id           => $class->_string( 'id', $data->{id} ),
    endpoint_ref => $class->_string( 'endpoint_ref', $data->{endpoint_ref} ),
    ( exists $data->{capabilities} ? ( capabilities => $data->{capabilities} ) : () ),
  );
}

=method from_hash

Builds a model entry from its JSON object form, rejecting unknown and
forbidden fields.

=cut

sub to_hash {
  my ($self) = @_;
  my $caps = $self->capabilities;
  return {
    id           => $self->id,
    endpoint_ref => $self->endpoint_ref,
    capabilities => {
      map { $_ => ( $caps->{$_} ? JSON::MaybeXS::true() : JSON::MaybeXS::false() ) } keys %$caps
    },
  };
}

=method to_hash

Returns the JSON object form; capability values are JSON booleans.

=cut

sub TO_JSON { shift->to_hash }

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Manifest> - The provider manifest

=item * L<Langertha::Role::Capabilities> - The capability vocabulary

=back

=cut

1;
