package Langertha::Engine::Remote;
# ABSTRACT: Base class for all remote engines
our $VERSION = '0.203';
use Moose;

with 'Langertha::Role::'.$_ for (qw(
  JSON
  HTTP
));

has '+url' => (
  required => 1,
);

__PACKAGE__->meta->make_immutable;

1;
