package Langertha::OpenAI::Chat;
# ABSTRACT: OpenAI Chat chain

use Moose;

with qw(
  Langertha::Role::Messages
);

has openai => (
  isa => 'Langertha::OpenAI',
  is => 'ro',
  required => 1,
  handles => [qw(
    parse_response
  )],
);

sub chat_request {
  my ( $self, $messages, %extra ) = @_;
  return $self->generate_request( generateChat =>
    model => $self->model,
    messages => $messages,
    stream => JSON->false,
    format => 'json',
    keep_alive => 5,
    %extra,
  );
}

sub chat_response {
  my ( $self, $response ) = @_;

}

1;