package Langertha::Engine::OpenAIResponses;
# ABSTRACT: OpenAI Responses API (reasoning models like gpt-5.5-pro)
our $VERSION = '0.503';
use Moose;

extends 'Langertha::Engine::OpenAI';

with 'Langertha::Role::ResponsesCompatible';

=head1 SYNOPSIS

    use Langertha::Engine::OpenAIResponses;

    my $engine = Langertha::Engine::OpenAIResponses->new(
        api_key => $ENV{OPENAI_API_KEY},
        model   => 'gpt-5.5-pro',   # reasoning-only model
    );

    my $response = $engine->simple_chat('Hello');
    print $response;

=head1 DESCRIPTION

Provides access to OpenAI's Responses API endpoint (C<POST /v1/responses>)
for reasoning-only models like C<gpt-5.5-pro>, C<o3-pro>, and future
C<-pro> SKUs that are not available on the Chat Completions endpoint
(C</v1/chat/completions>).

Unlike L<Langertha::Engine::OpenAI> which calls C</v1/chat/completions>, this
engine speaks the Open-Responses wire envelope: C<input> instead of
C<messages>, top-level C<instructions>, flat tool objects, and an C<output[]>
array with type discriminators. That envelope lives in
L<Langertha::Role::ResponsesCompatible> (parallel to
L<Langertha::Role::OpenAICompatible>); this engine is a thin shell that inherits
OpenAI's Bearer auth, API key and model list from L<Langertha::Engine::OpenAI>,
composes the Responses envelope on top, and opts out of streaming.

This engine returns a L<Langertha::Response> that is shape-compatible with
the chat path, so existing consumers (including Goldmine's C<complete>
method) work without modification. Reasoning tokens are normalized to
C<completion_tokens_details.reasoning_tokens> for cost lookup compatibility.

=head2 Structured output

Structured output goes under C<text.format> (a flat json_schema, not the
Chat-Completions nested shape); the Responses API has no C<response_format>
param. See L<Langertha::Role::ResponsesCompatible/_responses_format_kwargs>.

=head2 Function call output shape

The Responses API emits C<function_call> as a top-level C<output[]> item
(real reasoning models) or nested inside a message item (older fixtures);
C<chat_response> and L<Langertha::ToolCall/extract> walk both. Streaming is
not supported — L<Langertha::Role::ResponsesCompatible> can stream the
envelope, but this engine opts out (see below).

=cut

# Protocol variant of OpenAI: shares the vendor's API key.
sub api_key_env { 'LANGERTHA_OPENAI_API_KEY' }

# The Responses envelope role can stream (typed SSE), but this engine has never
# supported it. Opt out: stream_format => undef, and clear the streaming flag
# that Role::Streaming (inherited via Engine::OpenAI) would otherwise advertise
# (ADR 0002 escape hatch). Both together keep supports('streaming') honest.
sub stream_format { return undef }

around engine_capabilities => sub {
    my ( $orig, $self, @rest ) = @_;
    my $caps = $self->$orig(@rest);
    delete $caps->{streaming};
    return $caps;
};

__PACKAGE__->meta->make_immutable;

=head1 SEE ALSO

=over

=item * L<Langertha::Role::ResponsesCompatible> - the Open-Responses wire envelope

=item * L<Langertha::Engine::OpenAI> - Chat Completions endpoint (for non-reasoning models)

=item * L<Langertha::Engine::Perplexity> - the other Responses-envelope consumer (Agent API)

=item * L<Langertha::ToolCall> - Tool call extraction from Responses format

=item * L<Langertha::ToolChoice/to_responses> - Responses tool_choice serialization

=item * L<Langertha::Tool/to_responses> - Responses tool serialization

=back

=cut

1;
