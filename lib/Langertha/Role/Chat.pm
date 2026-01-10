package Langertha::Role::Chat;
# ABSTRACT: Role for APIs with normal chat functionality

use Moose::Role;
use Carp qw( croak );

requires qw(
  chat_request
  chat_response
);

has chat_model => (
  is => 'ro',
  isa => 'Str',
  lazy_build => 1,
);
sub _build_chat_model {
  my ( $self ) = @_;
  croak "".(ref $self)." can't handle models!" unless $self->does('Langertha::Role::Models');
  return $self->default_chat_model if $self->can('default_chat_model');
  return $self->model;
}

sub chat {
  my ( $self, @messages ) = @_;
  return $self->chat_request($self->chat_messages(@messages));
}

sub chat_messages {
  my ( $self, @messages ) = @_;
  return [$self->has_system_prompt
    ? ({
      role => 'system', content => $self->system_prompt,
    }) : (),
    map {
      ref $_ ? $_ : {
        role => 'user', content => $_,
      }
    } @messages];
}

sub simple_chat {
  my ( $self, @messages ) = @_;
  my $request = $self->chat(@messages);
  my $response = $self->user_agent->request($request);
  return $request->response_call->($response);
}

sub chat_stream {
  my ( $self, @messages ) = @_;
  croak "".(ref $self)." does not support streaming"
    unless $self->can('chat_stream_request');
  return $self->chat_stream_request($self->chat_messages(@messages));
}

sub simple_chat_stream {
  my ( $self, $callback, @messages ) = @_;
  croak "simple_chat_stream requires a callback as first argument"
    unless ref $callback eq 'CODE';
  my $request = $self->chat_stream(@messages);
  my $chunks = $self->execute_streaming_request($request, $callback);
  return join('', map { $_->content } @$chunks);
}

sub simple_chat_stream_iterator {
  my ( $self, @messages ) = @_;
  require Langertha::Stream;
  my $request = $self->chat_stream(@messages);
  my $chunks = $self->execute_streaming_request($request);
  return Langertha::Stream->new(chunks => $chunks);
}

1;
