package Langertha::Stream;
# ABSTRACT: Iterator for streaming responses
our $VERSION = '0.202';
use Moose;
use namespace::autoclean;
use Carp qw( croak );

=head1 SYNOPSIS

    my $stream = $engine->simple_chat_stream_iterator('Tell me a story');

    # Iterate chunk by chunk
    while (my $chunk = $stream->next) {
        print $chunk->content;
    }

    # Or use the callback form
    $stream->reset;
    $stream->each(sub {
        my ($chunk) = @_;
        print $chunk->content;
    });

    # Collect all remaining chunks
    my @chunks = $stream->collect;

    # Get complete content as a string
    my $full_text = $stream->content;

=head1 DESCRIPTION

An iterator object wrapping an array of L<Langertha::Stream::Chunk> objects
returned from a streaming LLM response. Created by
L<Langertha::Role::Chat/simple_chat_stream_iterator>.

The iterator maintains a position cursor so you can step through chunks one
at a time with C<next>, consume them all with C<collect> or C<each>, and
start over with C<reset>.

=cut

has chunks => (
  is => 'ro',
  isa => 'ArrayRef[Langertha::Stream::Chunk]',
  required => 1,
);

=attr chunks

ArrayRef of L<Langertha::Stream::Chunk> objects comprising the full streaming
response. Required.

=cut

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

=method next

    while (my $chunk = $stream->next) {
        print $chunk->content;
    }

Returns the next L<Langertha::Stream::Chunk> and advances the cursor, or
C<undef> when all chunks have been consumed.

=cut

sub has_next {
  my ($self) = @_;
  return $self->_position < scalar @{$self->chunks};
}

=method has_next

    if ($stream->has_next) { ... }

Returns true if there are more chunks to iterate over.

=cut

sub collect {
  my ($self) = @_;
  my @remaining;
  while (my $chunk = $self->next) {
    push @remaining, $chunk;
  }
  return @remaining;
}

=method collect

    my @chunks = $stream->collect;

Returns all remaining chunks as a list and advances the cursor to the end.

=cut

sub content {
  my ($self) = @_;
  return join('', map { $_->content } @{$self->chunks});
}

=method content

    my $text = $stream->content;

Returns the concatenated C<content> of all chunks in the stream as a single
string, regardless of the current cursor position.

=cut

sub each {
  my ($self, $callback) = @_;
  croak "each() requires a callback" unless ref $callback eq 'CODE';
  while (my $chunk = $self->next) {
    $callback->($chunk);
  }
}

=method each

    $stream->each(sub {
        my ($chunk) = @_;
        print $chunk->content;
    });

Iterates over all remaining chunks, calling C<$callback> with each
L<Langertha::Stream::Chunk>. Dies if no callback is provided.

=cut

sub reset {
  my ($self) = @_;
  $self->_position(0);
}

=method reset

    $stream->reset;

Resets the cursor to the beginning so the stream can be iterated again.

=cut

=seealso

=over

=item * L<Langertha::Stream::Chunk> - A single streaming chunk

=item * L<Langertha::Role::Chat> - Provides C<simple_chat_stream_iterator> that returns this object

=item * L<Langertha::Role::Streaming> - Stream parsing (SSE / NDJSON)

=back

=cut

__PACKAGE__->meta->make_immutable;

1;
