package Langertha::Role::JSON;
# ABSTRACT: Role for JSON

use Moose::Role;
use JSON::MaybeXS;

sub json { shift->_json }
has _json => (
  is => 'ro',
  lazy_build => 1,
);
sub _build__json { JSON::MaybeXS->new( utf8 => 1, canonical => 1 ) }

1;
