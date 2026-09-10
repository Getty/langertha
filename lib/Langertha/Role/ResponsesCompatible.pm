package Langertha::Role::ResponsesCompatible;
# ABSTRACT: Role for the Open-Responses wire envelope (input/instructions/output[])
our $VERSION = '0.503';
use Moose::Role;
use Carp qw( croak );
use JSON::MaybeXS;
use Langertha::ToolCall;
use Langertha::ToolChoice;
use Langertha::Response;

=head1 SYNOPSIS

    # Not used directly - composed by engines speaking the Responses envelope.

    package My::Engine;
    use Moose;

    extends 'Langertha::Engine::Remote';

    with map { 'Langertha::Role::'.$_ } qw(
        Models Temperature ReasoningEffort ResponseSize SystemPrompt
        ResponseFormat Streaming Chat ResponsesCompatible
    );

    __PACKAGE__->meta->make_immutable;

=head1 DESCRIPTION

The Open-Responses wire envelope, parallel to
L<Langertha::Role::OpenAICompatible> and L<Langertha::Role::AnthropicCompatible>.
This is the request/response/stream shape that OpenAI's C</v1/responses> API and
Perplexity's C</v1/agent> Agent API share:

=over 4

=item * C<input> instead of C<messages> (typed items, system messages lifted out)

=item * C<instructions> for the system prompt (top-level, not in C<input>)

=item * C<output[]> array discriminated by C<type> (C<message>, C<reasoning>,
C<function_call>) instead of C<choices[]>

=item * C<input_tokens>/C<output_tokens> instead of
C<prompt_tokens>/C<completion_tokens>

=item * flat tool objects C<{ type, name, description, parameters }> and the
C<responses> C<tool_wire_format> / C<reasoning_wire_format>

=back

The role owns the body builder, the C<output[]> response walker, the usage
normalization, and the typed-SSE stream parser. It does B<not> own
authentication (each consumer supplies its own C<api_key> / C<update_request>,
so this role never clobbers an inherited key builder) nor the capability
corrections (an engine that opts out of streaming, or narrows the
C<response_format> enum, does so on itself).

=head2 Divergence hooks

Two consumers speak this envelope from different parents and diverge on a
handful of slots; each is an overridable method with the OpenAI-Responses
default baked in:

=over 4

=item * L</_responses_model_kwargs> - C<model> vs C<preset> (or C<models>)
selection.

=item * L</_responses_format_kwargs> - structured output slot: OpenAI's
C<text.format> (flat json_schema) vs the Chat-Completions-shaped top-level
C<response_format>.

=item * L</_responses_dispatch> - how the built body reaches the wire: an
OpenAPI operation (C<createResponse> -> C</v1/responses>) vs a direct
C<POST> to a provider path.

=item * L</_normalize_input_item> - per-item shaping of the C<input> array.

=item * L</_responses_extra_fields> - extra L<Langertha::Response> constructor
args pulled from the raw payload (e.g. Perplexity citations).

=back

=cut

# The Responses envelope carries flat tools and nested reasoning:{effort}.
# These override the openai defaults inherited from Role::Tools /
# Role::ReasoningEffort; on a lean consumer (parent = Remote) they are supplied
# with -excludes on those roles (ADR 0015), the same way AnthropicBase wires
# Role::AnthropicCompatible.
sub _build_tool_wire_format { 'responses' }
sub _build_reasoning_wire_format { 'responses' }

# Default endpoint is the OpenAI Responses operation; Perplexity's Agent engine
# overrides _responses_dispatch to POST /v1/agent directly.
sub chat_operation_id { 'createResponse' }

sub chat_request {
    my ( $self, $messages, %extra ) = @_;

    # Canonical per-request controls (chat_f, karr #46) beat the engine
    # attributes on a per-key basis; the rest of %extra passes straight through.
    my $controls = delete $extra{controls} // {};

    # Normalize tool_choice to the Responses (flat function) format. Pinned to
    # the literal 'responses' rather than $self->tool_wire_format: the envelope
    # is always Responses-shaped, and a lean consumer (Perplexity) composes no
    # Role::Tools, so it carries no tool_wire_format attribute at all (mirrors
    # OpenAICompatible pinning 'openai').
    if ( exists $extra{tool_choice} && defined $extra{tool_choice} ) {
        if ( my $tc = Langertha::ToolChoice->from_hash( $extra{tool_choice} ) ) {
            $extra{tool_choice} = $tc->to('responses');
        }
    }

    # If tools passed in MCP format (inputSchema camelCase), format them to the
    # flat Responses shape. Guarded by can(): a lean consumer that composes no
    # Role::Tools (Perplexity) never receives tools, and has no format_tools.
    if ( exists $extra{tools} && ref $extra{tools} eq 'ARRAY'
      && $self->can('format_tools') ) {
        my @tools = @{$extra{tools}};
        if ( @tools && ref $tools[0] eq 'HASH' && !exists $tools[0]{type} ) {
            $extra{tools} = $self->format_tools(\@tools);
        }
    }

    # parallel_tool_use -> parallel_tool_calls (only when tools present).
    if ( exists $extra{tools} && !exists $extra{parallel_tool_calls} ) {
        my $ptu;
        if ( exists $controls->{parallel_tool_use} ) {
            $ptu = $controls->{parallel_tool_use};
        }
        elsif ( $self->can('has_parallel_tool_use') && $self->has_parallel_tool_use ) {
            $ptu = $self->parallel_tool_use;
        }
        $extra{parallel_tool_calls} = $ptu ? JSON->true : JSON->false if defined $ptu;
    }

    # Build input array: strip system messages (they go to instructions).
    my @input;
    for my $msg (@$messages) {
        next if ( $msg->{role} // '' ) eq 'system';
        push @input, $self->_normalize_input_item($msg);
    }

    # Structured output. Per-request control beats the engine attribute; the
    # wire slot is chosen by the consumer via _responses_format_kwargs.
    my $response_format =
        exists $controls->{response_format} ? $controls->{response_format}
      : ( $self->can('has_response_format') && $self->has_response_format )
                                            ? $self->response_format
      :                                       undef;

    my @request_args = (
        $self->_responses_model_kwargs,
        $self->has_system_prompt ? ( instructions => $self->system_prompt ) : (),
        scalar(@input) ? ( input => \@input ) : (),
        exists $controls->{max_tokens}
            ? ( max_output_tokens => $controls->{max_tokens} )
            : ( $self->get_response_size ? ( max_output_tokens => $self->get_response_size ) : () ),
        defined $response_format
            ? $self->_responses_format_kwargs($response_format)
            : (),
        exists $controls->{temperature}
            ? ( temperature => $controls->{temperature} )
            : ( $self->has_temperature ? ( temperature => $self->temperature ) : () ),
        exists $controls->{seed} ? ( seed => $controls->{seed} ) : (),
        ( $self->can('reasoning_kwargs_for') ? $self->reasoning_kwargs_for(%$controls) : () ),
        stream => JSON->false,
        %extra,
    );

    return $self->_responses_dispatch(
        sub { $self->chat_response(shift) },
        @request_args,
    );
}

=method chat_request

    my $request = $engine->chat_request($messages, %extra);

Builds an Open-Responses request body (C<input> / C<instructions> / model or
preset / optional structured-output slot / C<reasoning> / C<max_output_tokens>
/ C<temperature>) and hands it to L</_responses_dispatch>. Returns an HTTP
request object.

=cut

# --- Divergence hooks (OpenAI-Responses defaults) ------------------------

sub _responses_model_kwargs {
    my ( $self ) = @_;
    return defined $self->chat_model ? ( model => $self->chat_model ) : ();
}

=method _responses_model_kwargs

Returns the model-selection kwargs for the body. Default emits
C<< model => chat_model >>. Overridden by consumers that select a C<preset>
or C<models[]> instead (Perplexity maps its user-facing model ids to presets).

=cut

sub _responses_format_kwargs {
    my ( $self, $rf ) = @_;
    return ( text => { format => $self->_responses_text_format($rf) } );
}

=method _responses_format_kwargs

Returns the structured-output kwargs for the body from a Chat-Completions-shaped
C<response_format> hash. Default is OpenAI's C<< text => { format => ... } >>
(flat json_schema, see L</_responses_text_format>). Overridden by consumers
whose wire keeps the top-level Chat-Completions C<response_format> shape
(Perplexity).

=cut

sub _responses_dispatch {
    my ( $self, $response_call, @request_args ) = @_;
    return $self->generate_request(
        $self->chat_operation_id,
        $response_call,
        @request_args,
    );
}

=method _responses_dispatch

Turns the built body into an HTTP request. Default resolves the endpoint from
the OpenAPI spec via L</chat_operation_id> (C<createResponse> ->
C</v1/responses>). Overridden by consumers on a non-OpenAPI parent to
C<POST> a fixed provider path directly (Perplexity -> C</v1/agent>).

=cut

sub _normalize_input_item {
    my ( $self, $msg ) = @_;
    # Pass through for the OpenAI Responses wire; consumers that require a typed
    # {type:message,...} item (Perplexity) override this.
    return $msg;
}

=method _normalize_input_item

Shapes one C<input> array item from a normalized chat message. Default passes
the C<{ role, content }> hash through unchanged. Overridden by consumers that
require an explicit item C<type>.

=cut

sub _responses_extra_fields {
    my ( $self, $data ) = @_;
    return ();
}

=method _responses_extra_fields

Returns extra L<Langertha::Response> constructor args pulled from the raw
response payload. Default empty. Overridden by consumers that surface
provider-specific fields (Perplexity lifts C<search_results> into
L<Langertha::Response/citations>).

=cut

# Translate an OpenAI Chat-Completions response_format hash into the value the
# Responses API wants under text.format. On the Chat wire the schema is nested
# (`{ type => 'json_schema', json_schema => { name, schema, strict } }`); the
# Responses wire pulls that inner object up one level (flat json_schema). A
# json_object stays a bare type; anything unrecognized (or already flat) passes
# through unchanged so we never mangle a shape we do not model.
sub _responses_text_format {
    my ( $self, $rf ) = @_;
    return $rf unless ref $rf eq 'HASH';
    my $type = $rf->{type} // '';
    if ( $type eq 'json_schema' && ref $rf->{json_schema} eq 'HASH' ) {
        return { %{ $rf->{json_schema} }, type => 'json_schema' };
    }
    if ( $type eq 'json_object' ) {
        return { type => 'json_object' };
    }
    return $rf;
}

# --- Response parsing ----------------------------------------------------

sub chat_response {
    my ( $self, $response ) = @_;
    my $data = $self->parse_response($response);

    my ( $text, @tc_data, $finish_reason, $thinking );

    for my $item ( @{ $data->{output} // [] } ) {
        next unless ref($item) eq 'HASH';
        my $type = $item->{type} // '';

        if ( $type eq 'reasoning' ) {
            my $summary = $item->{summary}[0]{text} // '';
            $thinking //= $summary if length $summary;
        }
        elsif ( $type eq 'message' ) {
            $finish_reason = ( $item->{status} // '' ) eq 'completed' ? 'stop' : ( $item->{status} // '' );

            for my $block ( @{ $item->{content} // [] } ) {
                my $block_type = $block->{type} // '';
                if ( $block_type eq 'output_text' ) {
                    $text .= ( $block->{text} // '' );
                }
                elsif ( $block_type eq 'function_call' ) {
                    push @tc_data, $block;
                }
            }
        }
        elsif ( $type eq 'function_call' ) {
            # Real Responses API emits function_call as a top-level output[]
            # item carrying name/arguments/call_id directly on the item.
            push @tc_data, $item;
            $finish_reason //= 'tool_calls';
        }
    }

    # Normalize usage to chat-style (Langertha::Usage / Goldmine expect
    # prompt_tokens/completion_tokens).
    my $usage = $data->{usage} // {};
    my $normalized_usage = {
        prompt_tokens     => $usage->{input_tokens},
        completion_tokens => $usage->{output_tokens},
        total_tokens      => $usage->{total_tokens},
    };
    if ( my $rt = $usage->{output_tokens_details}{reasoning_tokens} ) {
        $normalized_usage->{completion_tokens_details} = { reasoning_tokens => $rt };
    }

    my @tcs = map { $self->_parse_function_call($_) } @tc_data;

    return Langertha::Response->new(
        content       => $text // '',
        raw           => $data,
        $data->{id}      ? ( id => $data->{id} )      : (),
        $data->{model}   ? ( model => $data->{model} ) : (),
        defined $finish_reason ? ( finish_reason => $finish_reason ) : (),
        usage         => $normalized_usage,
        # created_at is the Responses envelope's epoch stamp; Response.BUILDARGS
        # runs it through Langertha::Moment->from_wire (ADR 0017), which drops it
        # if unreadable rather than failing the whole reply.
        defined $data->{created_at} ? ( created => $data->{created_at} ) : (),
        @tcs ? ( tool_calls => \@tcs ) : (),
        defined $thinking ? ( thinking => $thinking ) : (),
        $self->_responses_extra_fields($data),
    );
}

=method chat_response

    my $response = $engine->chat_response($http_response);

Walks the C<output[]> array (C<message> / C<reasoning> / top-level
C<function_call>), normalizes usage, maps C<created_at> to
L<Langertha::Response/created>, and returns a L<Langertha::Response>. Extra
provider fields come from L</_responses_extra_fields>.

=cut

sub _parse_function_call {
    my ( $self, $block ) = @_;
    my $args = $block->{arguments} // '{}';
    $args = $self->decode_json_text($args) if $args && !ref $args;
    return Langertha::ToolCall->new(
        name      => ( $block->{name} // '' ),
        arguments => ( ref($args) eq 'HASH' ? $args : {} ),
        id        => ( $block->{call_id} // '' ),
    );
}

# --- Streaming (typed SSE) -----------------------------------------------

sub stream_format { 'sse' }

=method stream_format

    my $format = $engine->stream_format;

Returns C<'sse'>. The Responses/Agent stream is a typed SSE stream. A consumer
that does not stream (OpenAI's Responses engine) overrides this to C<undef> and
clears the C<streaming> capability.

=cut

sub chat_stream_request {
    my ( $self, $messages, %extra ) = @_;

    my $controls = delete $extra{controls} // {};

    if ( exists $extra{tool_choice} && defined $extra{tool_choice} ) {
        if ( my $tc = Langertha::ToolChoice->from_hash( $extra{tool_choice} ) ) {
            $extra{tool_choice} = $tc->to('responses');
        }
    }

    my @input;
    for my $msg (@$messages) {
        next if ( $msg->{role} // '' ) eq 'system';
        push @input, $self->_normalize_input_item($msg);
    }

    my $response_format =
        exists $controls->{response_format} ? $controls->{response_format}
      : ( $self->can('has_response_format') && $self->has_response_format )
                                            ? $self->response_format
      :                                       undef;

    my @request_args = (
        $self->_responses_model_kwargs,
        $self->has_system_prompt ? ( instructions => $self->system_prompt ) : (),
        scalar(@input) ? ( input => \@input ) : (),
        exists $controls->{max_tokens}
            ? ( max_output_tokens => $controls->{max_tokens} )
            : ( $self->get_response_size ? ( max_output_tokens => $self->get_response_size ) : () ),
        defined $response_format
            ? $self->_responses_format_kwargs($response_format)
            : (),
        exists $controls->{temperature}
            ? ( temperature => $controls->{temperature} )
            : ( $self->has_temperature ? ( temperature => $self->temperature ) : () ),
        exists $controls->{seed} ? ( seed => $controls->{seed} ) : (),
        ( $self->can('reasoning_kwargs_for') ? $self->reasoning_kwargs_for(%$controls) : () ),
        stream => JSON->true,
        %extra,
    );

    return $self->_responses_dispatch( sub {}, @request_args );
}

=method chat_stream_request

    my $request = $engine->chat_stream_request($messages, %extra);

Builds a streaming (C<stream => true>) Open-Responses request. Returns an HTTP
request object for streaming execution.

=cut

sub parse_stream_chunk {
    my ( $self, $data, $event ) = @_;

    require Langertha::Stream::Chunk;

    # The Responses/Agent stream is typed: each data payload carries a `type`
    # naming the event (the `event:` SSE line, when present, mirrors it). Text
    # arrives as response.output_text.delta with the increment in `delta`; the
    # terminal response.completed carries usage. `data: [DONE]` is consumed by
    # Role::Streaming before this is called.
    #
    # LIVE-CONFIRM (k139): exact typed-SSE framing (event names, the `.delta`
    # field, whether usage rides on response.completed vs a trailing frame, and
    # the interleaving of reasoning / search / tool events) is documented but
    # not yet verified against a live Agent-API stream. Built to the documented
    # OpenAI-Responses streaming shape.
    my $type = ref($data) eq 'HASH' ? ( $data->{type} // ( $event // '' ) ) : '';

    if ( $type eq 'response.output_text.delta' ) {
        return Langertha::Stream::Chunk->new(
            content  => ( $data->{delta} // '' ),
            raw      => $data,
            is_final => 0,
        );
    }

    if ( $type eq 'response.completed' || $type eq 'response.incomplete' ) {
        my $resp  = $data->{response} // {};
        my $usage = $resp->{usage};
        return Langertha::Stream::Chunk->new(
            content  => '',
            raw      => $data,
            is_final => 1,
            $resp->{model} ? ( model => $resp->{model} ) : (),
            $usage ? ( usage => {
                prompt_tokens     => $usage->{input_tokens},
                completion_tokens => $usage->{output_tokens},
                total_tokens      => $usage->{total_tokens},
            } ) : (),
        );
    }

    # Every other typed event (response.created, response.output_item.added,
    # reasoning / search deltas, ...) carries no assistant text -> skip.
    return undef;
}

=method parse_stream_chunk

    my $chunk = $engine->parse_stream_chunk($data, $event);

Parses one typed-SSE data payload from a Responses/Agent stream. Returns a
L<Langertha::Stream::Chunk> for C<response.output_text.delta> (text) and the
terminal C<response.completed> (final, usage), C<undef> for every other typed
event.

=cut

=seealso

=over

=item * L<Langertha::Engine::OpenAIResponses> - OpenAI C</v1/responses> consumer

=item * L<Langertha::Engine::Perplexity> - Perplexity C</v1/agent> Agent API consumer

=item * L<Langertha::Role::OpenAICompatible> - the parallel Chat-Completions envelope

=item * L<Langertha::Role::AnthropicCompatible> - the parallel Anthropic envelope

=item * L<Langertha::ToolCall> - tool-call extraction (C<responses> format)

=item * L<Langertha::Reasoning/to_responses> - C<reasoning:{effort}> serialization

=back

=cut

1;
