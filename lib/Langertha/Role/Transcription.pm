package Langertha::Role::Transcription;
# ABSTRACT: Role for APIs with transcription functionality

use Moose::Role;
use Carp qw( croak );

requires qw(
  transcription_request
  transcription_response
);

has transcription_model => (
  is => 'ro',
  isa => 'Str',
  lazy_build => 1,
);
sub _build_transcription_model {
  my ( $self ) = @_;
  croak "".(ref $self)." can't handle models!" unless $self->does('Langertha::Role::Models');
  return $self->default_transcription_model if $self->can('default_transcription_model');
  return $self->model;
}

sub transcription {
  my ( $self, $file_or_content, %extra ) = @_;
  return $self->transcription_request($file_or_content, %extra);
}

sub simple_transcription {
  my ( $self, $file_or_content, %extra ) = @_;
  my $request = $self->transcription($file_or_content, %extra);
  my $response = $self->user_agent->request($request);
  return $request->response_call->($response);
}

1;
