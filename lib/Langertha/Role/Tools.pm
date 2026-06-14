package Langertha::Role::Tools;
# ABSTRACT: Role for MCP tool calling support
our $VERSION = '0.503';
use Moose::Role;
use Future::AsyncAwait;
use Carp qw( croak );
use JSON::MaybeXS;
use Log::Any qw( $log );
use Langertha::Tool;
use Langertha::ToolCall;
use Langertha::ToolResult;

with 'Langertha::Role::ParallelToolUse';

=head1 SYNOPSIS

    use IO::Async::Loop;
    use Net::Async::MCP;
    use Future::AsyncAwait;

    my $loop = IO::Async::Loop->new;

    # Set up an MCP server with tools
    my $mcp = Net::Async::MCP->new(server => $my_mcp_server);
    $loop->add($mcp);
    await $mcp->initialize;

    # Create engine with MCP servers (native tool calling)
    my $engine = Langertha::Engine::Anthropic->new(
        api_key     => $ENV{ANTHROPIC_API_KEY},
        model       => 'claude-sonnet-4-6',
        mcp_servers => [$mcp],
    );

    my $response = await $engine->chat_with_tools_f(
        'Use the available tools to answer my question'
    );

    # Hermes tool calling (for APIs without native tool support)
    my $engine = Langertha::Engine::AKI->new(
        api_key     => $ENV{AKI_API_KEY},
        mcp_servers => [$mcp],
    );

=head1 DESCRIPTION

This role adds MCP (Model Context Protocol) tool calling support to Langertha
engines. It provides the L</chat_with_tools_f> method which implements the full
async tool-calling loop:

=over 4

=item 1. Gather available tools from all configured MCP servers

=item 2. Send a chat request with tool definitions to the LLM

=item 3. If the LLM returns tool calls, execute them via MCP

=item 4. Feed tool results back to the LLM and repeat

=item 5. When the LLM returns final text, return it

=back

All tool wire-translation is tag-driven: an engine declares its dialect via
L</tool_wire_format> (C<openai> | C<anthropic> | C<gemini> | C<ollama> |
C<responses> | C<hermes>) and the default implementations of C<format_tools>,
C<response_tool_calls>, C<extract_tool_call>, C<format_tool_results>, and
C<response_text_content> delegate to the L<Langertha::Tool>,
L<Langertha::ToolCall>, and L<Langertha::ToolResult> value objects keyed by that
tag. Engines carry no per-format tool code. The C<hermes> dialect injects tools
into the system prompt and parses C<E<lt>tool_callE<gt>> XML; its tag names and
prompt template come from L<Langertha::Role::HermesTools>.

=cut

has mcp_servers => (
  is => 'ro',
  isa => 'ArrayRef',
  default => sub { [] },
);

=attr mcp_servers

    mcp_servers => [$mcp1, $mcp2]

ArrayRef of L<Net::Async::MCP> instances to use as tool providers. Defaults to
an empty ArrayRef. At least one server must be configured before calling
L</chat_with_tools_f>.

=cut

has tool_max_iterations => (
  is => 'ro',
  isa => 'Int',
  default => 10,
);

=attr tool_max_iterations

    tool_max_iterations => 20

Maximum number of tool-calling round trips before aborting with an error.
Defaults to C<10>. Increase for complex multi-step tool workflows.

=cut

has tool_wire_format => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  builder => '_build_tool_wire_format',
);

sub _build_tool_wire_format { 'openai' }

=attr tool_wire_format

    tool_wire_format => 'anthropic'

The single per-engine enum naming which tool dialect this engine speaks —
C<openai> | C<anthropic> | C<gemini> | C<ollama> | C<responses> | C<hermes>.
This one tag drives all tool wire-translation: the outbound tool definitions
(L<Langertha::Tool>), the inbound tool calls (L<Langertha::ToolCall>), the
result blocks (L<Langertha::ToolResult>), the final-text extraction, and the
outbound transport (native API parameter vs. Hermes prompt injection).

The default follows the engine base-class hierarchy: C<OpenAIBase> leaves it at
C<openai>, C<AnthropicBase> overrides to C<anthropic>, and so on — so the ~25
concrete engines inherit it and carry no tool-format code of their own. Override
C<_build_tool_wire_format> to change it.

=cut

# The five tool-format methods below are tag-driven defaults: they delegate to
# the Langertha::Tool / ToolCall / ToolResult value objects keyed by
# L</tool_wire_format>. Engines no longer carry per-format copies.

sub build_tool_chat_request {
  my ( $self, $conversation, $formatted_tools, %extra ) = @_;
  if ( $self->tool_wire_format eq 'hermes' ) {
    my $tools_json  = $self->json->encode($formatted_tools);
    my $tool_prompt = sprintf( $self->hermes_tool_prompt, $tools_json );
    my @conv = ( { role => 'system', content => $tool_prompt }, @$conversation );
    return $self->chat_request( \@conv, %extra );
  }
  return $self->chat_request( $conversation, tools => $formatted_tools, %extra );
}

=method build_tool_chat_request

    my $request = $self->build_tool_chat_request($conversation, $formatted_tools);

Builds an HTTP request for a tool-calling chat turn. For native wire formats the
tools are passed as an API parameter via C<chat_request>; for the C<hermes>
format they are injected into the system prompt as XML.

=cut

sub format_tools {
  my ( $self, $mcp_tools ) = @_;
  return Langertha::Tool->format_list( $self->tool_wire_format, $mcp_tools );
}

=method format_tools

    my $tools = $engine->format_tools($mcp_tools);

Converts an ArrayRef of MCP tool definitions to the wire C<tools> payload for
this engine's L</tool_wire_format> via L<Langertha::Tool/format_list>.

=cut

sub response_tool_calls {
  my ( $self, $data ) = @_;
  my $fmt = $self->tool_wire_format;
  if ( $fmt eq 'hermes' ) {
    my $content = $self->hermes_extract_content($data);
    return [] unless $content;
    my $tag = $self->hermes_call_tag;
    my @tool_calls;
    while ( $content =~ m{<\Q$tag\E>\s*(.*?)\s*</\Q$tag\E>}sg ) {
      my $json_str = $1;
      eval {
        my $tc = $self->decode_json_text($json_str);
        push @tool_calls, $tc;
      };
    }
    return \@tool_calls;
  }
  return Langertha::ToolCall->locate( $fmt, $data );
}

=method response_tool_calls

    my $tool_calls = $engine->response_tool_calls($raw_data);

Returns the ArrayRef of raw tool-call structures located in C<$raw_data> for
this engine's format (via L<Langertha::ToolCall/locate>). For C<hermes>, parses
the C<E<lt>tool_callE<gt>> XML tags out of the model's text. May be empty.

=cut

sub extract_tool_call {
  my ( $self, $tc ) = @_;
  my $fmt = $self->tool_wire_format;
  return ( $tc->{name}, $tc->{arguments} ) if $fmt eq 'hermes';
  my $call = Langertha::ToolCall->from_fmt( $fmt, $tc );
  return $call ? ( $call->name, $call->arguments ) : ( undef, undef );
}

=method extract_tool_call

    my ($name, $args) = $engine->extract_tool_call($tool_call);

Extracts the tool name and decoded argument HashRef from a single raw tool-call
structure, via L<Langertha::ToolCall/from_fmt>.

=cut

sub response_text_content {
  my ( $self, $data ) = @_;
  my $fmt = $self->tool_wire_format;
  if ( $fmt eq 'openai' ) {
    my $choice = $data->{choices}[0] or return '';
    return $choice->{message}{content} // '';
  }
  if ( $fmt eq 'ollama' ) {
    my $msg = $data->{message} or return '';
    return $msg->{content} // '';
  }
  if ( $fmt eq 'anthropic' ) {
    return join( '',
      map { $_->{text} } grep { $_->{type} eq 'text' } @{ $data->{content} // [] } );
  }
  if ( $fmt eq 'gemini' ) {
    my $candidates = $data->{candidates} || [];
    return '' unless @$candidates;
    my $parts = $candidates->[0]{content}{parts} || [];
    return join( '', map { $_->{text} } grep { exists $_->{text} } @$parts );
  }
  if ( $fmt eq 'responses' ) {
    my $text = '';
    for my $item ( @{ $data->{output} // [] } ) {
      next unless ref($item) eq 'HASH';
      next unless ( $item->{type} // '' ) eq 'message';
      for my $block ( @{ $item->{content} // [] } ) {
        $text .= ( $block->{text} // '' ) if ( $block->{type} // '' ) eq 'output_text';
      }
    }
    return $text;
  }
  if ( $fmt eq 'hermes' ) {
    my $content = $self->hermes_extract_content($data) // '';
    my $tag = $self->hermes_call_tag;
    $content =~ s{<\Q$tag\E>.*?</\Q$tag\E>}{}sg;
    $content =~ s/^\s+|\s+$//g;
    return $content;
  }
  return '';
}

=method response_text_content

    my $text = $engine->response_text_content($raw_data);

Extracts the assistant's final text content from a raw response, per
L</tool_wire_format>. For C<hermes>, strips C<E<lt>tool_callE<gt>> tags.

=cut

sub format_tool_results {
  my ( $self, $data, $results ) = @_;
  my $fmt = $self->tool_wire_format;

  if ( $fmt eq 'anthropic' ) {
    my @blocks = map {
      Langertha::ToolResult->new(
        id       => ( $_->{tool_call}{id} // '' ),
        content  => ( $_->{result}{content} // [] ),
        is_error => ( $_->{result}{isError} ? 1 : 0 ),
      )->to('anthropic')
    } @$results;
    return (
      { role => 'assistant', content => $data->{content} },
      { role => 'user',      content => \@blocks },
    );
  }

  if ( $fmt eq 'gemini' ) {
    my @parts = map {
      Langertha::ToolResult->new(
        name    => ( $_->{tool_call}{functionCall}{name} // '' ),
        content => ( $_->{result}{content} // [] ),
      )->to('gemini')
    } @$results;
    my $candidate = $data->{candidates}[0];
    return (
      { role => 'model', parts => $candidate->{content}{parts} },
      { role => 'user',  parts => \@parts },
    );
  }

  if ( $fmt eq 'ollama' ) {
    return (
      { role       => 'assistant',
        content    => $data->{message}{content},
        tool_calls => $data->{message}{tool_calls} },
      map {
        Langertha::ToolResult->new( content => ( $_->{result}{content} // [] ) )->to('ollama')
      } @$results,
    );
  }

  if ( $fmt eq 'responses' ) {
    return [
      map {
        Langertha::ToolResult->new(
          id      => ( $_->{tool_call}{call_id} // $_->{tool_call}{id} // '' ),
          content => ( $_->{result}{content} // [] ),
        )->to('responses')
      } @$results
    ];
  }

  if ( $fmt eq 'hermes' ) {
    my $content = $self->hermes_extract_content($data);
    my $res_tag = $self->hermes_response_tag;
    return (
      { role => 'assistant', content => $content },
      map {
        { role    => 'tool',
          content => Langertha::ToolResult->new(
            name    => ( $_->{tool_call}{name} // '' ),
            content => ( $_->{result}{content} // [] ),
          )->to( 'hermes', response_tag => $res_tag ) }
      } @$results,
    );
  }

  # openai (default)
  my $choice = $data->{choices}[0];
  return (
    { role       => 'assistant',
      content    => $choice->{message}{content},
      tool_calls => $choice->{message}{tool_calls} },
    map {
      Langertha::ToolResult->new(
        id      => ( $_->{tool_call}{id} // '' ),
        content => ( $_->{result}{content} // [] ),
      )->to('openai')
    } @$results,
  );
}

=method format_tool_results

    my @messages = $engine->format_tool_results($raw_data, $results);

Assembles tool execution results into the provider-shaped message envelope for
the next turn: the assistant echo of the prior turn plus one
L<Langertha::ToolResult> block per result (arity varies by format).

=cut

async sub chat_with_tools_f {
  my ( $self, @messages ) = @_;

  croak "No MCP servers configured" unless @{$self->mcp_servers};

  # Gather tools from all MCP servers
  my ( @all_tools, %tool_server_map );
  for my $mcp (@{$self->mcp_servers}) {
    my $tools = await $mcp->list_tools;
    for my $tool (@$tools) {
      $tool_server_map{$tool->{name}} = $mcp;
      push @all_tools, $tool;
    }
  }

  my $formatted_tools = $self->format_tools(\@all_tools);
  my $conversation = $self->chat_messages(@messages);

  $log->debugf("[%s] chat_with_tools_f: %d tools from %d MCP servers, max_iterations=%d",
    ref $self, scalar @all_tools, scalar @{$self->mcp_servers}, $self->tool_max_iterations);

  for my $iteration (1..$self->tool_max_iterations) {
    $log->debugf("[%s] Tool loop iteration %d/%d",
      ref $self, $iteration, $self->tool_max_iterations);

    my $request = $self->build_tool_chat_request($conversation, $formatted_tools);
    my $response = await $self->_async_http->do_request(request => $request);

    unless ($response->is_success) {
      die "".(ref $self)." tool chat request failed: ".$response->status_line;
    }

    my $data = $self->parse_response($response);
    my $tool_calls = $self->response_tool_calls($data);

    # No tool calls means the LLM is done — return final text
    unless (@$tool_calls) {
      my $text = $self->response_text_content($data);
      if ($self->think_tag_filter) {
        ($text) = $self->filter_think_content($text);
      }
      return $text;
    }

    # Execute each tool call via the appropriate MCP server
    my @results;
    for my $tc (@$tool_calls) {
      my ( $name, $input ) = $self->extract_tool_call($tc);

      $log->debugf("[%s] Calling tool: %s", ref $self, $name);

      my $mcp = $tool_server_map{$name}
        or die "Tool '$name' not found on any MCP server";

      my $result = await $mcp->call_tool($name, $input)->else(sub {
        my ( $error ) = @_;
        Future->done({
          content => [{ type => 'text', text => "Error calling tool '$name': $error" }],
          isError => JSON::MaybeXS->true,
        });
      });

      push @results, { tool_call => $tc, result => $result };
    }

    # Append assistant message and tool results to conversation
    push @$conversation, $self->format_tool_results($data, \@results);
  }

  die "Tool calling loop exceeded ".$self->tool_max_iterations." iterations";
}

=method chat_with_tools_f

    my $response = await $engine->chat_with_tools_f(@messages);

Async tool-calling chat loop. Accepts the same message arguments as
L<Langertha::Role::Chat/simple_chat>. Gathers tools from all L</mcp_servers>,
sends the request, executes any tool calls returned by the LLM, and repeats
until the LLM returns a final text response or L</tool_max_iterations> is
exceeded. Returns a L<Future> that resolves to the final text response.

=cut

=seealso

=over

=item * L<Langertha::Role::HermesTools> - Hermes-style tool calling via XML tags

=item * L<Langertha::Role::Chat> - Chat role this is built on top of

=item * L<Langertha::Raider> - Autonomous agent with persistent history using tools

=item * L<Net::Async::MCP> - MCP client used as tool provider

=item * L<Langertha::Engine::Anthropic> - Engine with native tool support

=back

=cut

1;
