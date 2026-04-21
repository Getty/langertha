package Langertha::Role::HermesTools;
# ABSTRACT: Hermes-style tool calling via XML tags
our $VERSION = '0.403';
use Moose::Role;
use JSON::MaybeXS;

=head1 SYNOPSIS

    package Langertha::Engine::MyEngine;
    use Moose;
    extends 'Langertha::Engine::Remote';

    with 'Langertha::Role::Tools';
    with 'Langertha::Role::HermesTools';

=head1 DESCRIPTION

This role implements tool calling via Hermes-style XML tags. Instead of using
an API's native C<tools> parameter, tool definitions are injected into the
system prompt as C<E<lt>toolsE<gt>> XML and the model responds with
C<E<lt>tool_callE<gt>> XML tags containing JSON. This works with any chat
model regardless of native tool API support.

Engines composing this role get implementations of the five methods required
by L<Langertha::Role::Tools>: L</format_tools>, L</response_tool_calls>,
L</extract_tool_call>, L</format_tool_results>, and L</response_text_content>.
It also provides L</build_tool_chat_request> to inject tools into the system
prompt instead of passing them as an API parameter.

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

# --- Role::Tools method implementations ---

sub format_tools {
  my ( $self, $tools ) = @_;
  return $tools;
}

=method format_tools

Returns the MCP tool definitions as-is for JSON encoding into the Hermes
system prompt.

=cut

around build_tool_chat_request => sub {
  my ( $orig, $self, $conversation, $formatted_tools, %extra ) = @_;
  my $tools_json = $self->json->encode($formatted_tools);
  my $tool_prompt = sprintf($self->hermes_tool_prompt, $tools_json);
  my $system_msg = { role => 'system', content => $tool_prompt };
  my @conv = ( $system_msg, @$conversation );
  return $self->chat_request(\@conv, %extra);
};

=method build_tool_chat_request

Builds a chat request with tool definitions injected into the system prompt
as XML, rather than passing them as an API parameter.

=cut

sub response_tool_calls {
  my ( $self, $data ) = @_;
  my $content = $self->hermes_extract_content($data);
  return [] unless $content;

  my $tag = $self->hermes_call_tag;
  my @tool_calls;
  while ($content =~ m{<\Q$tag\E>\s*(.*?)\s*</\Q$tag\E>}sg) {
    my $json_str = $1;
    eval {
      my $tc = $self->decode_json_text($json_str);
      push @tool_calls, $tc;
    };
  }
  return \@tool_calls;
}

=method response_tool_calls

Parses C<E<lt>tool_callE<gt>> XML tags from the model's text output and
returns an ArrayRef of tool call HashRefs with C<name> and C<arguments>.

=cut

sub extract_tool_call {
  my ( $self, $tc ) = @_;
  return ( $tc->{name}, $tc->{arguments} );
}

=method extract_tool_call

Extracts tool name and arguments from a Hermes tool call HashRef.

=cut

sub response_text_content {
  my ( $self, $data ) = @_;
  my $content = $self->hermes_extract_content($data) // '';
  my $tag = $self->hermes_call_tag;
  $content =~ s{<\Q$tag\E>.*?</\Q$tag\E>}{}sg;
  $content =~ s/^\s+|\s+$//g;
  return $content;
}

=method response_text_content

Extracts the final text content from the response, stripping any
C<E<lt>tool_callE<gt>> XML tags.

=cut

sub format_tool_results {
  my ( $self, $data, $results ) = @_;
  my $content = $self->hermes_extract_content($data);
  my $res_tag = $self->hermes_response_tag;

  my @messages;
  push @messages, { role => 'assistant', content => $content };

  for my $r (@$results) {
    my $tool_content = join('', map { $_->{text} // '' } @{$r->{result}{content}});
    push @messages, {
      role => 'tool',
      content => "<${res_tag}>\n"
        . $self->json->encode({ name => $r->{tool_call}{name}, content => $tool_content })
        . "\n</${res_tag}>",
    };
  }

  return @messages;
}

=method format_tool_results

Formats tool execution results as C<E<lt>tool_responseE<gt>> XML messages
for the next conversation turn.

=cut

=seealso

=over

=item * L<Langertha::Role::Tools> - Base tool calling role

=item * L<Langertha::Engine::NousResearch> - Hermes model engine

=item * L<Langertha::Engine::AKI> - AKI.IO engine using Hermes tools

=back

=cut

1;
