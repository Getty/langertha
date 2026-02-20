package Langertha::Role::OpenAPI;
# ABSTRACT: Role for APIs with OpenAPI definition
our $VERSION = '0.101';
use Moose::Role;

use Carp qw( croak );
use JSON::MaybeXS ();
use JSON::PP ();
use OpenAPI::Modern;
use Path::Tiny;
use URI;
use YAML::PP;

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

has supported_operations => (
  is => 'ro',
  isa => 'ArrayRef[Str]',
  lazy_build => 1,
);
sub _build_supported_operations {
  my ( $self ) = @_;
  return [];
}

sub can_operation {
  my ( $self, $operationId ) = @_;
  return 1 unless scalar @{$self->supported_operations} > 0;
  my %so = map { $_, 1 } @{$self->supported_operations};
  return $so{$operationId};
}

sub get_operation {
  my ( $self, $operationId ) = @_;
  croak "".(ref $self)." runs in compatibility mode and is unable to perform this OpenAPI operation"
    unless ($self->can_operation($operationId));
  my $jpath = $self->openapi->openapi_document->get_operationId_path($operationId);
  my $operation = $self->openapi->openapi_document->get($jpath);
  my $content_type = ( $operation->{requestBody} && $operation->{requestBody}->{content} )
    ? $operation->{requestBody}->{content}->{'application/json'} ? 'application/json'
      : $operation->{requestBody}->{content}->{'multipart/form-data'} ? 'multipart/form-data'
        : undef
    : undef;
  my ( undef, $paths, $path, $method ) = split('/', $jpath);
  return unless $paths eq 'paths';
  $path =~ s/~1/\//g;
  my $url = $self->url || $self->openapi->openapi_document->get('/servers/0/url');
  return ( uc($method), $url.$path, $content_type );
}

sub generate_request {
  my ( $self, $operationId, $response_call, %args ) = @_;
  my ( $method, $url, $content_type ) = $self->get_operation($operationId);
  $args{content_type} = $content_type if defined $content_type;
  return $self->generate_http_request( $method, $url, $response_call, %args );
}

1;
