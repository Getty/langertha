package Langertha::Role::OpenAPI;

use Moose::Role;

use Carp qw( croak );
use HTTP::Request;
use JSON::MaybeXS ();
use JSON::PP ();
use MIME::Base64 qw( encode_base64 );
use OpenAPI::Modern;
use Path::Tiny;
use URI;
use YAML::PP;

requires qw( openapi_file );

has url => (
  is => 'ro',
  predicate => 'has_url',
);

has json => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_json { JSON::MaybeXS->new( utf8 => 1, canonical => 1 ) }

has openapi => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_openapi {
  my ( $self ) = @_;
  my ( $format, $file ) = $self->openapi_file;
  # format assumed to be yaml
  my $yaml = $file;
  return OpenAPI::Modern->new(
    openapi_uri => $yaml,
    openapi_schema => YAML::PP->new(boolean => 'JSON::PP')->load_string(path($yaml)->slurp_utf8),
    $self->has_url ? ( base_url => $self->url ) : ());
}

sub get_operation {
  my ( $self, $operationId ) = @_;
  my $jpath = $self->openapi->openapi_document->get_operationId_path($operationId);
  my $operation = $self->openapi->openapi_document->get($jpath);
  my ( undef, $paths, $path, $method ) = split('/', $jpath);
  return unless $paths eq 'paths';
  $path =~ s/~1/\//g;
  my $url = $self->url || $self->openapi->openapi_document->get('/servers/0/url');
  $operation->{url} = URI->new($url.$path);
  $operation->{method} = uc($method);
  return $operation;
}

sub generate_body {
  my ( $self, %args ) = @_;
  return $self->json->encode({ %args });
}

sub generate_request {
  my ( $self, $operationId, %args ) = @_;
  my $operation = $self->get_operation($operationId);
  my $uri = $operation->{url};
  my $userinfo = $uri->userinfo;
  $uri->userinfo(undef) if $userinfo;
  my $headers = [];
  my $request = HTTP::Request->new(
    $operation->{method}, $operation->{url}, $headers,
    scalar %args > 0 ? $self->generate_body(%args) : (),
  );
  if ($userinfo) {
    my ( $user, $pass ) = split(/:/, $userinfo);
    if ($user and $pass) {
      $request->authorization_basic($user, $pass);
    }
  }
  $self->update_request($request) if $self->can('update_request');
  return $request;
}

1;
