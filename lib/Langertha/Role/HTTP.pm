package Langertha::Role::HTTP;
# ABSTRACT: Role for HTTP APIs

use Moose::Role;

use Carp qw( croak );
use URI;
use LWP::UserAgent;

use Langertha::Request::HTTP;

requires qw(
  json
);

has url => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_url',
);

sub generate_body {
  my ( $self, %args ) = @_;
  return $self->json->encode({ %args });
}

sub generate_http_request {
  my ( $self, $method, $url, $response_call, %args ) = @_;
  my $uri = URI->new($url);
  my $userinfo = $uri->userinfo;
  $uri->userinfo(undef) if $userinfo;
  my $headers = [];
  my $request = Langertha::Request::HTTP->new(
    http => [ uc($method), $uri, $headers, ( scalar %args > 0 ? $self->generate_body(%args) : () ) ],
    request_source => $self,
    response_call => $response_call,
  );
  if ($userinfo) {
    my ( $user, $pass ) = split(/:/, $userinfo);
    if ($user and $pass) {
      $request->authorization_basic($user, $pass);
    }
  }
  $request->header('Content-Type', 'application/json; charset=utf-8');
  $self->update_request($request) if $self->can('update_request');
  return $request;
}

sub parse_response {
  my ( $self, $response ) = @_;
  croak "".(ref $self)." request failed: ".($response->status_line) unless $response->is_success;
  return $self->json->decode($response->decoded_content);
}

has user_agent_timeout => (
  isa => 'Int',
  is => 'ro',
  predicate => 'has_user_agent_timeout',
);

has user_agent_agent => (
  isa => 'Str',
  is => 'ro',
  lazy_build => 1,
);
sub _build_user_agent_agent {
  my ( $self ) = @_;
  return "".(ref $self)."";
}

has user_agent => (
  isa => 'LWP::UserAgent',
  is => 'ro',
  lazy_build => 1,
);
sub _build_user_agent {
  my ( $self ) = @_;
  return LWP::UserAgent->new(
    agent => $self->user_agent_agent,
    $self->has_user_agent_timeout ? ( timeout => $self->user_agent_timeout ) : (),
  );
}

1;
