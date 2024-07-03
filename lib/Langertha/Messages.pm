package Langertha::Messages;
# ABSTRACT: Generic chain of messages

use Moose;

has messages => (
  traits  => ['Array'],
  is => 'ro',
  isa => 'ArrayRef[Langertha::Message]',
  required => 1,
  handles => {
    all_messages => 'elements',
    add_message => 'push',
    map_messages => 'map',
    grep_messages => 'grep',
    count_messages => 'count',
  },
);

# simple shortcut for accessing last chat message content
sub last_content {
  my ( $self ) = @_;
  my @messages = reverse $self->all_messages;
  return $messages[0]->content;
}

sub to_api {
  my ( $self ) = @_;
  return [map { $_->to_api } $self->all_messages];
}

1;