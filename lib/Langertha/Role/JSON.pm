package Langertha::Role::JSON;
# ABSTRACT: Role for JSON
our $VERSION = '0.203';
use Moose::Role;
use JSON::MaybeXS;

sub json { shift->_json }

=method json

    my $data = $engine->json->decode($json_string);
    my $json_string = $engine->json->encode($data);

Returns the shared L<JSON::MaybeXS> instance configured with C<utf8> and
C<canonical> encoding. Used internally by L<Langertha::Role::HTTP> and
L<Langertha::Role::Streaming> for all JSON serialization.

=cut

has _json => (
  is => 'ro',
  lazy_build => 1,
);
sub _build__json { JSON::MaybeXS->new( utf8 => 1, canonical => 1 ) }

=seealso

=over

=item * L<Langertha::Role::HTTP> - HTTP role that requires this

=item * L<JSON::MaybeXS> - The JSON backend used

=back

=cut

1;
