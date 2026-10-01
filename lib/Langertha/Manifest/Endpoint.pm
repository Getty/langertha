package Langertha::Manifest::Endpoint;
# ABSTRACT: One endpoint of a provider manifest: wire dialect, base URL, auth reference
our $VERSION = '0.504';
use Moose;
with 'Langertha::Manifest::Validation';

=head1 SYNOPSIS

    my $endpoint = Langertha::Manifest::Endpoint->new(
      id       => 'chat',
      dialect  => 'openai-chat',
      base_url => 'https://provider.example/v1',
      auth_ref => 'api',
    );

    if ( $endpoint->is_known_dialect ) { ... }

=head1 DESCRIPTION

An endpoint of a L<Langertha::Manifest>: where to talk (C<base_url>), which
wire envelope to speak (C<dialect>) and which auth mechanism it needs
(C<auth_ref>, absent when it needs none). Immutable; validated on
construction.

=cut

# The v1 dialect vocabulary, derived from the engine hierarchy (ADR 0006:
# inheritance encodes the wire dialect) and named after the tool_wire_format
# tag where the two coincide. openai-chat carries a suffix because OpenAI
# ships two envelopes (/chat/completions and /responses).
# anthropic-compat is the /anthropic shim variant of the Messages envelope:
# same envelope, but structured output is emulated with a synthetic tool plus
# a forced tool_choice instead of first-party output_config.format.
my @KNOWN_DIALECTS = qw(
  openai-chat responses perplexity-agent anthropic anthropic-compat gemini ollama aki lmstudio
);
my %KNOWN_DIALECT = map { $_ => 1 } @KNOWN_DIALECTS;

has id       => ( is => 'ro', isa => 'Str', required => 1 );
has dialect  => ( is => 'ro', isa => 'Str', required => 1 );
has base_url => ( is => 'ro', isa => 'Str', required => 1 );
has auth_ref => ( is => 'ro', isa => 'Maybe[Str]', default => sub { undef } );

=attr id

Local id of the endpoint, unique within the manifest; models point at it
with C<endpoint_ref>.

=attr dialect

The wire dialect token (see L</known_dialects>). A pattern-valid but unknown
dialect is accepted — whether a client has an adapter for it is
L</is_known_dialect>, a separate question from validity.

=attr base_url

C<http>/C<https> URL; exactly what a Langertha engine of this dialect takes
as C<url> (the dialect decides which path it appends). Printable ASCII,
never carries userinfo, a query string or a fragment. This keeps the usual
credential carriers out of a published URL; it is best effort — a secret
embedded in the path itself cannot be told apart from a real path.

=attr auth_ref

Id of the L<Langertha::Manifest::Auth> entry this endpoint needs, or
C<undef> when it needs no credentials.

=cut

sub BUILD {
  my ($self) = @_;
  $self->_check_id( 'id', $self->id );
  $self->_check_token( 'dialect', $self->dialect );
  $self->_check_url( 'base_url', $self->base_url );
  $self->_check_id( 'auth_ref', $self->auth_ref ) if defined $self->auth_ref;
  return;
}

sub known_dialects { return @KNOWN_DIALECTS }

=method known_dialects

    my @dialects = Langertha::Manifest::Endpoint->known_dialects;

The v1 dialect vocabulary: C<openai-chat>, C<responses>,
C<perplexity-agent>, C<anthropic> (first-party Messages API),
C<anthropic-compat> (the C</anthropic> shims: structured output via a
synthetic tool and forced choice), C<gemini>, C<ollama>, C<aki>,
C<lmstudio>.

=cut

sub is_known_dialect { return $KNOWN_DIALECT{ $_[0]->dialect } ? 1 : 0 }

=method is_known_dialect

True when L</dialect> is in the v1 vocabulary.

=cut

sub from_hash {
  my ( $class, $data ) = @_;
  $class->_check_fields( $data,
    required => [qw( id dialect base_url )],
    optional => [qw( auth_ref )],
  );
  return $class->new(
    map { exists $data->{$_} ? ( $_ => $class->_string( $_, $data->{$_} ) ) : () }
      qw( id dialect base_url auth_ref )
  );
}

=method from_hash

    my $endpoint = Langertha::Manifest::Endpoint->from_hash(\%data);

Builds an endpoint from its JSON object form, rejecting unknown and
forbidden fields.

=cut

sub to_hash {
  my ($self) = @_;
  return {
    id       => $self->id,
    dialect  => $self->dialect,
    base_url => $self->base_url,
    ( defined $self->auth_ref ? ( auth_ref => $self->auth_ref ) : () ),
  };
}

=method to_hash

Returns the JSON object form; C<auth_ref> is omitted when undefined.

=cut

sub TO_JSON { shift->to_hash }

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Manifest> - The provider manifest

=back

=cut

1;
