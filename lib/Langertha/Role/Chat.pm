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

1;
