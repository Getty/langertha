package Langertha::Role::Tools;
# ABSTRACT: Role for MCP tool calling support

use Moose::Role;
use Future::AsyncAwait;
use Carp qw( croak );

requires qw(
  format_tools
  response_tool_calls
  format_tool_results
  response_text_content
);

has mcp_servers => (
  is => 'ro',
  isa => 'ArrayRef',
  default => sub { [] },
);

has tool_max_iterations => (
  is => 'ro',
  isa => 'Int',
  default => 10,
);

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

  for my $iteration (1..$self->tool_max_iterations) {

    # Send chat request with tools
    my $request = $self->chat_request($conversation, tools => $formatted_tools);
    my $response = await $self->_async_http->do_request(request => $request);

    unless ($response->is_success) {
      die "".(ref $self)." tool chat request failed: ".$response->status_line;
    }

    my $data = $self->parse_response($response);
    my $tool_calls = $self->response_tool_calls($data);

    # No tool calls means the LLM is done — return final text
    unless (@$tool_calls) {
      return $self->response_text_content($data);
    }

    # Execute each tool call via the appropriate MCP server
    my @results;
    for my $tc (@$tool_calls) {
      my $name = $tc->{name};
      my $mcp = $tool_server_map{$name}
        or die "Tool '$name' not found on any MCP server";

      my $result = await $mcp->call_tool($name, $tc->{input})->else(sub {
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

1;

=head1 SYNOPSIS

  use IO::Async::Loop;
  use Net::Async::MCP;
  use Future::AsyncAwait;

  my $loop = IO::Async::Loop->new;

  # Set up an MCP server with tools
  my $mcp = Net::Async::MCP->new(server => $my_mcp_server);
  $loop->add($mcp);
  await $mcp->initialize;

  # Create engine with MCP servers
  my $engine = Langertha::Engine::Anthropic->new(
    api_key     => $ENV{ANTHROPIC_API_KEY},
    model       => 'claude-sonnet-4-5-20250929',
    mcp_servers => [$mcp],
  );

  # Async tool-calling chat loop
  my $response = await $engine->chat_with_tools_f(
    'Use the available tools to answer my question'
  );

=head1 DESCRIPTION

This role adds MCP (Model Context Protocol) tool calling support to
Langertha engines. It provides the C<chat_with_tools_f> method which
implements the full async tool-calling loop:

=over 4

=item 1. Gather available tools from all configured MCP servers

=item 2. Send chat request with tool definitions to the LLM

=item 3. If the LLM returns tool calls, execute them via MCP

=item 4. Feed tool results back to the LLM and repeat

=item 5. When the LLM returns final text, return it

=back

Engines that compose this role must implement four methods to handle
the engine-specific tool format conversion. See L</REQUIRED METHODS>.

=head1 REQUIRED METHODS

Engines composing this role must implement:

=over 4

=item C<format_tools(\@mcp_tools)>

Convert MCP tool definitions to the engine's native tool format.

=item C<response_tool_calls(\%response_data)>

Extract tool call objects from a parsed LLM response.

=item C<format_tool_results(\%response_data, \@results)>

Format tool execution results as messages to append to the conversation.

=item C<response_text_content(\%response_data)>

Extract the final text content from a parsed LLM response.

=back

=attr mcp_servers

  mcp_servers => [$mcp1, $mcp2]

ArrayRef of L<Net::Async::MCP> instances to use as tool providers.

=attr tool_max_iterations

  tool_max_iterations => 20

Maximum number of tool-calling round trips before aborting. Defaults to 10.

=method chat_with_tools_f

  my $response = await $engine->chat_with_tools_f(@messages);

Async tool-calling chat loop. Accepts the same message arguments as
C<simple_chat>. Returns a L<Future> that resolves to the final text
response after all tool calls have been executed.

=seealso L<Net::Async::MCP>, L<Langertha::Role::Chat>

=cut
