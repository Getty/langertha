package Langertha::Role::Tools;
# ABSTRACT: Role for MCP tool calling support
our $VERSION = '0.101';
use Moose::Role;
use Future::AsyncAwait;
use Carp qw( croak );
use JSON::MaybeXS;

requires qw(
  format_tools
  response_tool_calls
  extract_tool_call
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

# --- Hermes-native tool calling support ---
# When enabled, tools are injected into the system prompt as <tools> XML
# and <tool_call> tags are parsed from the model's text output instead of
# using the API's native tool calling parameter.

has hermes_tools => (
  is => 'ro',
  isa => 'Bool',
  default => 0,
);

has hermes_call_tag => (
  is => 'ro',
  isa => 'Str',
  default => 'tool_call',
);

has hermes_response_tag => (
  is => 'ro',
  isa => 'Str',
  default => 'tool_response',
);

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

# Override this for engines with non-OpenAI response formats (e.g. Ollama native)
sub hermes_extract_content {
  my ( $self, $data ) = @_;
  return undef unless $data && $data->{choices} && @{$data->{choices}};
  return $data->{choices}[0]{message}{content};
}

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

  # Hermes mode: build system prompt with tool definitions once
  my $hermes_system_msg;
  if ($self->hermes_tools) {
    my $tools_json = $self->json->encode($formatted_tools);
    my $tool_prompt = sprintf($self->hermes_tool_prompt, $tools_json);
    $hermes_system_msg = { role => 'system', content => $tool_prompt };
  }

  for my $iteration (1..$self->tool_max_iterations) {

    # Build and send the request
    my $request;
    if ($self->hermes_tools) {
      # Hermes: tools go into system prompt, not as API parameter
      my @conv = ( $hermes_system_msg, @$conversation );
      $request = $self->chat_request(\@conv);
    } else {
      # API-native: pass tools as parameter
      $request = $self->chat_request($conversation, tools => $formatted_tools);
    }

    my $response = await $self->_async_http->do_request(request => $request);

    unless ($response->is_success) {
      die "".(ref $self)." tool chat request failed: ".$response->status_line;
    }

    my $data = $self->parse_response($response);

    # Extract tool calls
    my $tool_calls;
    if ($self->hermes_tools) {
      $tool_calls = $self->_hermes_parse_tool_calls($data);
    } else {
      $tool_calls = $self->response_tool_calls($data);
    }

    # No tool calls means the LLM is done — return final text
    unless (@$tool_calls) {
      if ($self->hermes_tools) {
        return $self->_hermes_text_content($data);
      }
      return $self->response_text_content($data);
    }

    # Execute each tool call via the appropriate MCP server
    my @results;
    for my $tc (@$tool_calls) {
      my ( $name, $input );
      if ($self->hermes_tools) {
        ( $name, $input ) = ( $tc->{name}, $tc->{arguments} );
      } else {
        ( $name, $input ) = $self->extract_tool_call($tc);
      }

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
    if ($self->hermes_tools) {
      push @$conversation, $self->_hermes_build_tool_results($data, \@results);
    } else {
      push @$conversation, $self->format_tool_results($data, \@results);
    }
  }

  die "Tool calling loop exceeded ".$self->tool_max_iterations." iterations";
}

# --- Hermes helper methods ---

sub _hermes_parse_tool_calls {
  my ( $self, $data ) = @_;
  my $content = $self->hermes_extract_content($data);
  return [] unless $content;

  my $tag = $self->hermes_call_tag;
  my @tool_calls;
  while ($content =~ m{<\Q$tag\E>\s*(.*?)\s*</\Q$tag\E>}sg) {
    my $json_str = $1;
    eval {
      my $tc = $self->json->decode($json_str);
      push @tool_calls, $tc;
    };
  }
  return \@tool_calls;
}

sub _hermes_text_content {
  my ( $self, $data ) = @_;
  my $content = $self->hermes_extract_content($data) // '';
  my $tag = $self->hermes_call_tag;
  $content =~ s{<\Q$tag\E>.*?</\Q$tag\E>}{}sg;
  $content =~ s/^\s+|\s+$//g;
  return $content;
}

sub _hermes_build_tool_results {
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
    model       => 'claude-sonnet-4-6',
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

Engines that compose this role must implement five methods to handle
the engine-specific tool format conversion. See L</REQUIRED METHODS>.

=head1 HERMES TOOL CALLING

For models and APIs that do not support a native C<tools> parameter
(such as Nous Research Hermes models), set C<hermes_tools =E<gt> 1>
to enable Hermes-native tool calling via XML tags:

  my $engine = Langertha::Engine::NousResearch->new(
    api_key       => $ENV{NOUSRESEARCH_API_KEY},
    hermes_tools  => 1,
    mcp_servers   => [$mcp],
  );

When enabled, tools are injected into the system prompt as
C<E<lt>toolsE<gt>> XML and C<E<lt>tool_callE<gt>> tags are parsed from
the model's text output. The engine's native tool methods (C<format_tools>,
C<response_tool_calls>, etc.) are bypassed.

The XML tag names, the system prompt template, and the response content
extraction can all be customized:

  my $engine = Langertha::Engine::OpenAI->new(
    url                => 'https://my-custom-api.com/v1',
    api_key            => $ENV{API_KEY},
    model              => 'my-model',
    hermes_tools       => 1,
    hermes_call_tag    => 'function_call',     # default: tool_call
    hermes_response_tag => 'function_response', # default: tool_response
    mcp_servers        => [$mcp],
  );

=head1 REQUIRED METHODS

Engines composing this role must implement:

=over 4

=item C<format_tools(\@mcp_tools)>

Convert MCP tool definitions to the engine's native tool format.

=item C<response_tool_calls(\%response_data)>

Extract tool call objects from a parsed LLM response.

=item C<extract_tool_call(\%tool_call)>

Extract tool name and input from a native tool call object.
Returns C<($name, \%input)>.

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

=attr hermes_tools

  hermes_tools => 1

Enable Hermes-native tool calling via C<E<lt>tool_callE<gt>> XML tags.
When true, tools are injected into the system prompt and parsed from
the model's text output. Defaults to false.

=attr hermes_call_tag

  hermes_call_tag => 'function_call'

The XML tag name used for tool calls in the model's output.
Defaults to C<tool_call>. The prompt template and response parser
both use this tag.

=attr hermes_response_tag

  hermes_response_tag => 'function_response'

The XML tag name used when sending tool results back to the model.
Defaults to C<tool_response>.

=attr hermes_tool_instructions

  hermes_tool_instructions => 'You are a helpful assistant that can call functions.'

The instruction text prepended to the Hermes tool system prompt.
Change this to customize the model's behavior without touching
the structural XML template. The default instructs the model to
call functions without making assumptions about argument values.

=attr hermes_tool_prompt

  hermes_tool_prompt => <<'PROMPT'
  You are an assistant with access to tools.
  <tools>%s</tools>
  Use <tool_call>{"name": "...", "arguments": {...}}</tool_call> to call them.
  PROMPT

The full system prompt template used for Hermes tool calling. Must contain
a C<%s> placeholder where the tools JSON will be inserted. Built
automatically from C<hermes_tool_instructions> and C<hermes_call_tag>.
Override this only if you need full control over the prompt structure.

=method chat_with_tools_f

  my $response = await $engine->chat_with_tools_f(@messages);

Async tool-calling chat loop. Accepts the same message arguments as
C<simple_chat>. Returns a L<Future> that resolves to the final text
response after all tool calls have been executed.

=method hermes_extract_content

  my $content = $self->hermes_extract_content($data);

Extract raw text content from a parsed LLM response for Hermes tool
call parsing. Defaults to OpenAI format (C<choices[0].message.content>).
Override this in engines with non-OpenAI response formats.

=seealso L<Net::Async::MCP>, L<Langertha::Role::Chat>

=cut
