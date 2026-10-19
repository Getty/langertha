package Langertha::Role::StreamUsage;
# ABSTRACT: Role for an engine whose stream request asks for the token usage
our $VERSION = '0.504';
use Moose::Role;

=head1 SYNOPSIS

    package My::CompatibleEngine;
    use Moose;
    extends 'Langertha::Engine::OpenAIBase';
    with 'Langertha::Role::StreamUsage';

    # Caller side
    my ( $content, $chunks ) = await $engine->chat_stream_realtime_f(
      messages => [ { role => 'user', content => 'Hello' } ],
    );
    my $usage = $engine->aggregate_usage($chunks);   # the prompt and completion tokens

=head1 DESCRIPTION

Composing this role gives the engine the C<stream_usage> capability: its
C<chat_stream_request> asks the provider for the stream's token usage, and
the usage arrives as the stream's last chunk. On the OpenAI chat wire that is
C<< stream_options => { include_usage => true } >> on the request body, set by
L<Langertha::Role::OpenAICompatible/chat_stream_request>; the provider then
sends a frame with an empty C<choices> list and the C<usage> after the finish
chunk, which C<parse_stream_chunk> turns into a content-less, non-final
L<Langertha::Stream::Chunk> carrying C<usage>. Collect it with
L<Langertha::Role::Chat/aggregate_usage>.

The role has no attributes or methods: it only marks that the engine's wire
documents the option. Some OpenAI-compatible servers reject a body field they
do not know, so the option is sent only where the provider's API reference
names it (ADR 0038). Engines without the role send no C<stream_options>;
whether their stream reports usage anyway is the provider's affair (DeepSeek
and OpenRouter always do, Groq also under C<x_groq.usage>).

A C<stream_options> the caller passes to the stream request replaces the
engine's whole, so C<< stream_options => { include_usage => JSON->false } >>
turns the usage off for one request.

=seealso

=over

=item * L<Langertha::Role::Capabilities> - The C<stream_usage> flag

=item * L<Langertha::Role::OpenAICompatible/chat_stream_request> - Where the option goes on the wire

=item * L<Langertha::Role::Chat/aggregate_usage> - The stream's usage from its chunks

=back

=cut

1;
