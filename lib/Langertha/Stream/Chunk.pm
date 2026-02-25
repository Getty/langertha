package Langertha::Stream::Chunk;
# ABSTRACT: Represents a single chunk from a streaming response
our $VERSION = '0.203';
use Moose;
use namespace::autoclean;

=head1 SYNOPSIS

    my $stream = $engine->simple_chat_stream_iterator('Tell me a story');

    while (my $chunk = $stream->next) {
        print $chunk->content;

        if ($chunk->is_final) {
            say "\nModel: ", $chunk->model     if $chunk->has_model;
            say "Finish: ", $chunk->finish_reason if $chunk->has_finish_reason;
        }
    }

=head1 DESCRIPTION

A single text chunk delivered during a streaming LLM response. Each chunk
carries incremental content text and optional metadata. Chunks are collected
into a L<Langertha::Stream> iterator by
L<Langertha::Role::Chat/simple_chat_stream_iterator>.

=cut

has content => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

=attr content

The incremental text content delivered in this chunk. Required. For most
chunks this is a word or partial word; the final chunk may be an empty
string.

=cut

has raw => (
  is => 'ro',
  isa => 'HashRef',
  predicate => 'has_raw',
);

=attr raw

The raw parsed API response data for this chunk as a HashRef. Use
C<has_raw> to check whether it was provided.

=cut

has is_final => (
  is => 'ro',
  isa => 'Bool',
  default => 0,
);

=attr is_final

Boolean flag set to C<1> on the last chunk of a stream. Defaults to C<0>.

=cut

has model => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_model',
);

=attr model

The model identifier returned by the provider, if present. Use C<has_model>
to check availability.

=cut

has finish_reason => (
  is => 'ro',
  isa => 'Maybe[Str]',
  predicate => 'has_finish_reason',
);

=attr finish_reason

The reason the stream ended: C<stop>, C<length>, C<tool_calls>, etc.
Provider-specific values are preserved as-is. C<undef> on non-final chunks.
Use C<has_finish_reason> to check availability.

=cut

has usage => (
  is => 'ro',
  isa => 'Maybe[HashRef]',
  predicate => 'has_usage',
);

=attr usage

Token usage counts as a HashRef, if provided by the engine on the final
chunk. Keys vary by provider. Use C<has_usage> to check availability.

=cut

=seealso

=over

=item * L<Langertha::Stream> - Iterator that holds chunks

=item * L<Langertha::Response> - Non-streaming response object

=item * L<Langertha::Role::Chat> - Chat role that produces streams

=back

=cut

__PACKAGE__->meta->make_immutable;

1;
