package Langertha::Role::HermesTools;
# ABSTRACT: Hermes-style tool calling via XML tags
our $VERSION = '0.503';
use Moose::Role;
use JSON::MaybeXS;

=head1 SYNOPSIS

    package Langertha::Engine::MyEngine;
    use Moose;
    extends 'Langertha::Engine::Remote';

    with 'Langertha::Role::Tools';
    with 'Langertha::Role::HermesTools';

    sub _build_tool_wire_format { 'hermes' }

=head1 DESCRIPTION

This role configures Hermes-style tool calling: instead of using an API's
native C<tools> parameter, tool definitions are injected into the system prompt
as C<E<lt>toolsE<gt>> XML and the model responds with C<E<lt>tool_callE<gt>> XML
tags containing JSON. This works with any chat model regardless of native tool
API support.

The behaviour itself lives in the tag-driven defaults of
L<Langertha::Role::Tools> (selected by C<tool_wire_format =E<gt> 'hermes'>). This
role now only carries the Hermes-specific I<configuration> those defaults read:
the call/response tag names (L</hermes_call_tag>, L</hermes_response_tag>), the
prompt template (L</hermes_tool_prompt>), and the response-content extractor
(L</hermes_extract_content>). Compose it alongside L<Langertha::Role::Tools> and
set C<_build_tool_wire_format> to C<'hermes'>.

=cut

has hermes_call_tag => (
  is => 'ro',
  isa => 'Str',
  default => 'tool_call',
);

=attr hermes_call_tag

    hermes_call_tag => 'function_call'

The XML tag name used for tool calls in the model's output. Both the prompt
template and the response parser use this tag. Defaults to C<tool_call>.

=cut

has hermes_response_tag => (
  is => 'ro',
  isa => 'Str',
  default => 'tool_response',
);

=attr hermes_response_tag

    hermes_response_tag => 'function_response'

The XML tag name used when sending tool results back to the model. Defaults to
C<tool_response>.

=cut

has hermes_tool_instructions => (
  is => 'ro',
  isa => 'Str',
  lazy => 1,
  builder => '_build_hermes_tool_instructions',
);

sub _build_hermes_tool_instructions {
  return "You are a function calling AI model. You may call one or more"
    . " functions to assist with the user query. Don't make assumptions"
    . " about what values to plug into functions.";
}

=attr hermes_tool_instructions

    hermes_tool_instructions => 'You are a helpful assistant that can call functions.'

The instruction text prepended to the Hermes tool system prompt. Customize this
to change the model's behavior without altering the structural XML template. The
default instructs the model to call functions without making assumptions about
argument values.

=cut

has hermes_tool_prompt => (
  is => 'ro',
  isa => 'Str',
  lazy => 1,
  builder => '_build_hermes_tool_prompt',
);

sub _build_hermes_tool_prompt {
  my ( $self ) = @_;
  my $call_tag = $self->hermes_call_tag;
  my $instructions = $self->hermes_tool_instructions;
  return <<"PROMPT";
${instructions}

You are provided with function signatures within <tools></tools> XML tags:
<tools>
%s
</tools>

For each function call, return a JSON object with function name and arguments within <${call_tag}></${call_tag}> XML tags:
<${call_tag}>
{"name": "function_name", "arguments": {"arg1": "value1"}}
</${call_tag}>
PROMPT
}

=attr hermes_tool_prompt

The full system prompt template used for Hermes tool calling. Must contain a
C<%s> placeholder where the tools JSON will be inserted. Built automatically
from L</hermes_tool_instructions> and L</hermes_call_tag>. Override this only
if you need full control over the prompt structure.

=cut

sub hermes_extract_content {
  my ( $self, $data ) = @_;
  return undef unless $data && $data->{choices} && @{$data->{choices}};
  return $data->{choices}[0]{message}{content};
}

=method hermes_extract_content

    my $content = $self->hermes_extract_content($data);

Extracts raw text content from a parsed LLM response for Hermes tool call
parsing. Defaults to OpenAI response format (C<choices[0].message.content>).
Override this method in engines with non-OpenAI response structures.

=cut

# The tool-format behaviour (format_tools, response_tool_calls,
# extract_tool_call, response_text_content, format_tool_results,
# build_tool_chat_request) is provided by the tag-driven defaults in
# Langertha::Role::Tools for tool_wire_format => 'hermes'. This role now only
# carries the Hermes-specific configuration (tag names + prompt template) those
# defaults read.

=seealso

=over

=item * L<Langertha::Role::Tools> - Base tool calling role

=item * L<Langertha::Engine::NousResearch> - Hermes model engine

=item * L<Langertha::Engine::AKI> - AKI.IO engine using Hermes tools

=back

=cut

1;
