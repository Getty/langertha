package Langertha::Stream::Chunk;
# ABSTRACT: Represents a single chunk from a streaming response
our $VERSION = '0.503';
use Moose;
use Langertha::ToolCall;

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

has cached_tokens => (
  is => 'ro',
  isa => 'Maybe[Int]',
  predicate => 'has_cached_tokens',
);

has tool_calls => (
  is        => 'ro',
  isa       => 'Maybe[ArrayRef[Langertha::ToolCall]]',
  predicate => 'has_tool_calls',
);

=attr tool_calls

Optional ArrayRef of finished L<Langertha::ToolCall> objects that complete
on this chunk. Every call the model streams lands on exactly one chunk, as the
same object the non-streaming reply of that response carries on
L<Langertha::Response/tool_calls>; a chunk never holds a fragment. Where it
lands depends on the dialect:

=over

=item * Chat-Completions (L<Langertha::Role::OpenAICompatible>): the
C<delta.tool_calls> fragments are assembled per C<index>, and all calls land on
the chunk that carries C<finish_reason>.

=item * Anthropic Messages (L<Langertha::Role::AnthropicCompatible>): each
C<tool_use> block is assembled from its C<input_json_delta> fragments and lands
on the chunk for its C<content_block_stop>, before the final chunk.

=item * Gemini and Ollama native: calls arrive whole and land on the chunk that
carries them.

=item * Open-Responses (L<Langertha::Role::ResponsesCompatible>): the calls land
on the final chunk, read from the terminal C<response.completed> event.

=item * Hermes (L<Langertha::Role::HermesTools>, tools in the prompt): the
C<E<lt>tool_callE<gt>> blocks are withheld from C<content> and their calls land
on the final chunk (see L<Langertha::Role::Chat/chat_stream_realtime_f>).

=back

Most chunks have no tool calls — use C<has_tool_calls> to check, or
L<Langertha::Role::Chat/aggregate_tool_calls> to collect them all in stream
order.

=cut

has citations => (
  is        => 'ro',
  isa       => 'Maybe[ArrayRef]',
  predicate => 'has_citations',
);

=attr citations

Optional ArrayRef of search-augmented source citations, populated on the final
chunk when a search-augmented engine emits them mid-stream. The Open-Responses
envelope (L<Langertha::Engine::Perplexity>) lifts the C<search_results> block
out of the terminal C<response.completed> C<output[]> here, so a streamed reply
surfaces the same sources the non-streaming path exposes as
L<Langertha::Response/citations>. Most chunks carry none — use C<has_citations>
to check. L<Langertha::Stream/citations> reassembles them off the stream.

=cut

has thinking => (
  is        => 'ro',
  isa       => 'Maybe[Str]',
  predicate => 'has_thinking',
);

=attr thinking

Optional incremental chain-of-thought / reasoning text delivered in this
chunk, parallel to L</content> and L</tool_calls>. Populated by the dialect
stream parsers from their verified per-provider delta spelling — the
OpenAI-compatible C<delta.reasoning_content> / bare C<delta.reasoning>,
Anthropic's C<thinking_delta>, Gemini's C<thought> parts, and Ollama native
C<message.thinking>. Most chunks carry no thinking — use C<has_thinking> to
check. The full streamed thinking is reassembled by
L<Langertha::Role::Chat/aggregate_thinking>, the streaming counterpart of
L<Langertha::Response/thinking> on the non-streaming path.

=cut

=attr usage

Token usage counts as a HashRef, if provided by the engine on the final
chunk. Keys vary by provider. Use C<has_usage> to check availability.

=cut

=attr cached_tokens

Number of prompt tokens served from the prefix cache, if reported by the
provider on the final chunk. Populated from
C<usage.prompt_tokens_details.cached_tokens> on the OpenAI-compatible wire
(SGLang with C<return_cached_tokens_details> enabled, and other servers
that emit the detail block) and from C<usage.input_tokens_details.cached_tokens>
on the Open-Responses wire (OpenAI Responses / Perplexity Agent). C<undef>
when the provider does not report it. Use C<has_cached_tokens> to check
availability.

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
