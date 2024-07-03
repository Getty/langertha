package Langertha::Message;
# ABSTRACT: Generic message of a chat

use Moose;

has content => (
  is => 'ro',
  isa => 'Str|Undef',
  predicate => 'has_content',
);

has role => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has extra => (
  is => 'ro',
  isa => 'HashRef',
  predicate => 'has_extra',
);

sub to_api {
  my ( $self ) = @_;
  return {
    role => $self->role,
    # by default content is undef if not set
    content => $self->content,
    $self->has_extra ? (%{$self->extra}) : (),
  };
}

1;