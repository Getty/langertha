package Langertha::Role::ToolResultPDF;
# ABSTRACT: Role for an engine whose tool results carry PDFs the model reads
our $VERSION = '0.504';
use Moose::Role;

=head1 SYNOPSIS

    if ( $engine->supports('tool_result_pdf') ) {
        # a PDF a tool returns reaches the model as a document it reads
    }
    else {
        # it becomes a text placeholder:
        # "[resource] application/pdf <file:///docs/report.pdf> (12345 bytes)"
    }

=head1 DESCRIPTION

Composing this role gives the engine the C<tool_result_pdf> capability: a PDF
a tool returns (an MCP embedded resource whose blob is C<application/pdf>)
reaches the model as a native document it reads, in the tool-result form of
this engine's C<tool_wire_format>: an Anthropic C<document> block, an Open
Responses C<input_file> part, a Gemini C<functionResponse.parts[].inlineData>
(L<Langertha::ToolResult/DESCRIPTION>). Without the flag the PDF goes out as
the text placeholder. L<Langertha::Role::Tools/format_tool_results> reads the
flag.

L<Langertha::Role::Capabilities/engine_capabilities> keeps the flag only while
the engine's current C<tool_wire_format> has a native tool-result PDF form
(L<Langertha::ToolResult/carries_native>). Whether the model must also see
images is a fact of that wire (L<Langertha::ToolResult/native_needs_vision>),
so it holds for an engine forced onto the wire too:

=over

=item * the C<anthropic> wire reads a PDF without vision (a text-only model
gets the extracted text), so there the flag does not need C<image_input>; the
Anthropic family ties it to whether the endpoint takes Anthropic's source
blocks inside a C<tool_result> instead;

=item * on the C<responses> and C<gemini> wires PDF understanding is a vision
feature (OpenAI and Gemini document it so), so the flag needs C<image_input>
there (Gemini: Gemini 3 and later only).

=back

Perplexity's Agent API shares the Responses envelope but has no C<input_file>
in a function call output, so it does not compose this role (ADR 0039).

The role has no attributes or methods.

=seealso

=over

=item * L<Langertha::Role::Capabilities> - The C<tool_result_pdf> flag

=item * L<Langertha::Role::ToolResultImages> - The same for an image

=item * L<Langertha::ToolResult> - The per-wire tool-result forms

=back

=cut

1;
