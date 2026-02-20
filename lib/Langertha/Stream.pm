package Langertha::Stream;
# ABSTRACT: Iterator for streaming responses
our $VERSION = '0.101';
use Moose;
use namespace::autoclean;
use Carp qw( croak );

has chunks => (
  is => 'ro',
  isa => 'ArrayRef[Langertha::Stream::Chunk]',
  required => 1,
);

has _position => (
  is => 'rw',
  isa => 'Int',
  default => 0,
);

sub next {
  my ($self) = @_;
  my $pos = $self->_position;
  return undef if $pos >= scalar @{$self->chunks};
  $self->_position($pos + 1);
  return $self->chunks->[$pos];
}

sub has_next {
  my ($self) = @_;
  return $self->_position < scalar @{$self->chunks};
}

sub collect {
  my ($self) = @_;
  my @remaining;
  while (my $chunk = $self->next) {
    push @remaining, $chunk;
  }
  return @remaining;
}

sub content {
  my ($self) = @_;
  return join('', map { $_->content } @{$self->chunks});
}

sub each {
  my ($self, $callback) = @_;
  croak "each() requires a callback" unless ref $callback eq 'CODE';
  while (my $chunk = $self->next) {
    $callback->($chunk);
  }
}

sub reset {
  my ($self) = @_;
  $self->_position(0);
}

__PACKAGE__->meta->make_immutable;

1;
