package Langertha::Role::OpenAPI;
# ABSTRACT: Role for APIs with OpenAPI definition

use Moose::Role;

use Carp qw( croak );
use JSON::MaybeXS ();
use JSON::PP ();
use MIME::Base64 qw( encode_base64 );
use OpenAPI::Modern;
use Path::Tiny;
use URI;
use YAML::PP;

use Langertha::Request::HTTP;

requires qw(
  openapi_file
  generate_http_request
  url
  json
);

has openapi => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_openapi {
  my ( $self ) = @_;
  my ( $format, $file ) = $self->openapi_file;
  croak "".(ref $self)." can only do format yaml for the OpenAPI spec currently" unless $format eq 'yaml';
  my $yaml = $file;
  return OpenAPI::Modern->new(
    openapi_uri => $yaml,
    openapi_schema => YAML::PP->new(boolean => 'JSON::PP')->load_string(path($yaml)->slurp_utf8),
  );
}

sub get_operation {
  my ( $self, $operationId ) = @_;
  my $jpath = $self->openapi->openapi_document->get_operationId_path($operationId);
  my $operation = $self->openapi->openapi_document->get($jpath);
  my ( undef, $paths, $path, $method ) = split('/', $jpath);
  return unless $paths eq 'paths';
  $path =~ s/~1/\//g;
  my $url = $self->url || $self->openapi->openapi_document->get('/servers/0/url');
  return uc($method), $url.$path;
}

sub generate_request {
  my ( $self, $operationId, $response_call, %args ) = @_;
  my ( $method, $url ) = $self->get_operation($operationId);
  return $self->generate_http_request( $method, $url, $response_call, %args );
}

1;
