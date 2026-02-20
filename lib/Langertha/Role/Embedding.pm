package Langertha::Role::Embedding;
# ABSTRACT: Role for APIs with embedding functionality
our $VERSION = '0.101';
use Moose::Role;
use Carp qw( croak );

requires qw(
  embedding_request
  embedding_response
);

has embedding_model => (
  is => 'ro',
  isa => 'Str',
  lazy_build => 1,
);
sub _build_embedding_model {
  my ( $self ) = @_;
  croak "".(ref $self)." can't handle models!" unless $self->does('Langertha::Role::Models');
  return $self->default_embedding_model if $self->can('default_embedding_model');
  return $self->model;
}

sub embedding {
  my ( $self, $text ) = @_;
  return $self->embedding_request($text);
}

sub simple_embedding {
  my ( $self, $text ) = @_;
  my $request = $self->embedding($text);
  my $response = $self->user_agent->request($request);
  return $request->response_call->($response);
}

1;
