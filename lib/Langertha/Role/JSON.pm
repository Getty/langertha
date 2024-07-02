package Langertha::Role::JSON;
# ABSTRACT: Role for JSON

use Moose::Role;
use JSON::Streaming::Reader;

sub json { shift->_json }
has _json => (
  is => 'ro',
  lazy_build => 1,
);
sub _build__json { JSON::MaybeXS->new( utf8 => 1, canonical => 1 ) }

sub json_streaming_reader {
  my ( $self, $string, %process_tokens ) = @_;
  my $jsonr = JSON::Streaming::Reader->for_string(\$string);
  $jsonr->process_tokens(%process_tokens);
}

# TODO Parsing JSON
# use DDP;
# sub find_json {
#   my ( $self, $string ) = @_;
#   $self->json_streaming_reader($string,
#     start_object => sub { p(@_);1; },
#     end_object => sub { p(@_);1; },
#     start_array => sub { p(@_);1; },
#     end_array => sub { p(@_);1; },
#     add_string => sub { p(@_);1; },
#     add_number => sub { p(@_);1; },
#     add_boolean => sub { p(@_);1; },
#     add_null => sub { p(@_);1; },
#     error => sub { p(@_);1; },
#   );
# }

1;
