package Langertha::Chat;
# ABSTRACT: Chat abstraction wrapping an engine with optional overrides
our $VERSION = '0.304';
use Moose;
use Future::AsyncAwait;
use Carp qw( croak );
use JSON::MaybeXS;
use Log::Any qw( $log );

with 'Langertha::Role::PluginHost';

=head1 SYNOPSIS

    use Langertha::Engine::OpenAI;
    use Langertha::Chat;

    my $engine = Langertha::Engine::OpenAI->new(
        api_key => $ENV{OPENAI_API_KEY},
        model   => 'gpt-4o',
    );

    my $chat = Langertha::Chat->new(
        engine        => $engine,
        system_prompt => 'You are a helpful assistant.',
        plugins       => ['Langfuse'],
    );

    my $reply = $chat->simple_chat('Hello!');

    # With MCP tool calling
    my $chat_tools = Langertha::Chat->new(
        engine      => $engine,
        mcp_servers => [$mcp],
        plugins     => ['Langfuse'],
    );
    my $result = $chat_tools->simple_chat_with_tools('List files in /tmp');

=head1 DESCRIPTION

C<Langertha::Chat> wraps any engine that consumes L<Langertha::Role::Chat>
and adds optional overrides for model, system prompt, and temperature, plus
plugin lifecycle hooks via L<Langertha::Role::PluginHost>.

Use this class when you want to share a single engine instance across
multiple chat contexts with different configurations, or when you need
plugin observability (e.g. L<Langertha::Plugin::Langfuse>) without
modifying the engine itself.

=cut

has engine => (
  is       => 'ro',
  required => 1,
);

has system_prompt => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_system_prompt',
);

has model => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_model',
);

has temperature => (
  is        => 'ro',
  isa       => 'Num',
  predicate => 'has_temperature',
);

has mcp_servers => (
  is      => 'ro',
  isa     => 'ArrayRef',
  default => sub { [] },
);

has tool_max_iterations => (
  is      => 'ro',
  isa     => 'Int',
  default => 10,
);

=attr engine

The LLM engine to delegate chat requests to. Must consume
L<Langertha::Role::Chat>.

=attr system_prompt

Optional system prompt. When set, prepended to messages for each
request, overriding any system prompt on the engine itself.

=attr model

Optional model name override. When set, overrides the engine's
C<chat_model> via C<%extra> pass-through.

=attr temperature

Optional temperature override. When set, overrides the engine's
temperature.

=attr mcp_servers

ArrayRef of L<Net::Async::MCP> instances for tool calling.

=attr tool_max_iterations

Maximum tool-calling round trips. Defaults to C<10>.

=cut

sub _extra {
  my ( $self ) = @_;
  return (
    ($self->has_model       ? (model       => $self->model)       : ()),
    ($self->has_temperature ? (temperature => $self->temperature) : ()),
  );
}

sub _build_messages {
  my ( $self, @messages ) = @_;
  return [
    ($self->has_system_prompt
      ? ({ role => 'system', content => $self->system_prompt })
      : ()),
    map { ref $_ ? $_ : { role => 'user', content => $_ } } @messages
  ];
}

sub _assert_chat_engine {
  my ( $self ) = @_;
  my $engine = $self->engine;
  croak ref($engine) . " does not support chat"
    unless $engine->does('Langertha::Role::Chat');
  return $engine;
}

# --- Plugin hook runners (async) ---

async sub _run_plugin_before_llm_call {
  my ( $self, $conversation, $iteration ) = @_;
  for my $plugin (@{$self->_plugin_instances}) {
    $conversation = await $plugin->plugin_before_llm_call($conversation, $iteration);
  }
  return $conversation;
}

async sub _run_plugin_after_llm_response {
  my ( $self, $data, $iteration ) = @_;
  for my $plugin (@{$self->_plugin_instances}) {
    $data = await $plugin->plugin_after_llm_response($data, $iteration);
  }
  return $data;
}

async sub _run_plugin_after_tool_call {
  my ( $self, $name, $input, $result ) = @_;
  for my $plugin (@{$self->_plugin_instances}) {
    $result = await $plugin->plugin_after_tool_call($name, $input, $result);
  }
  return $result;
}

# --- Simple chat (no tools) ---

sub simple_chat {
  my ( $self, @messages ) = @_;
  $log->debugf("[Chat] simple_chat via %s", ref $self->engine);
  my $engine = $self->_assert_chat_engine;
  my $conversation = $self->_build_messages(@messages);

  $conversation = $self->_run_plugin_before_llm_call($conversation, 1)->get;

  my $request = $engine->chat_request($conversation, $self->_extra);
  my $response = $engine->user_agent->request($request);
  my $data = $request->response_call->($response);

  $data = $self->_run_plugin_after_llm_response($data, 1)->get;

  return $data;
}

=method simple_chat

    my $response = $chat->simple_chat('Hello!');

Sends a synchronous chat request. Fires C<plugin_before_llm_call> and
C<plugin_after_llm_response> hooks.

=cut

async sub simple_chat_f {
  my ( $self, @messages ) = @_;
  my $engine = $self->_assert_chat_engine;
  my $conversation = $self->_build_messages(@messages);

  $conversation = await $self->_run_plugin_before_llm_call($conversation, 1);

  my $request = $engine->chat_request($conversation, $self->_extra);
  my $response = await $engine->_async_http->do_request(
    request => $request,
  );
  unless ($response->is_success) {
    die "" . (ref $engine) . " request failed: " . $response->status_line;
  }
  my $data = $request->response_call->($response);

  $data = await $self->_run_plugin_after_llm_response($data, 1);

  return $data;
}

=method simple_chat_f

    my $response = await $chat->simple_chat_f('Hello!');

Async version of L</simple_chat>.

=cut

sub simple_chat_stream {
  my ( $self, $callback, @messages ) = @_;
  my $engine = $self->_assert_chat_engine;
  croak ref($engine) . " does not support streaming"
    unless $engine->can('chat_stream_request');
  croak "simple_chat_stream requires a callback as first argument"
    unless ref $callback eq 'CODE';
  my $conversation = $self->_build_messages(@messages);

  $conversation = $self->_run_plugin_before_llm_call($conversation, 1)->get;

  my $request = $engine->chat_stream_request($conversation, $self->_extra);
  my $chunks = $engine->execute_streaming_request($request, $callback);
  return join('', map { $_->content } @$chunks);
}

=method simple_chat_stream

    my $content = $chat->simple_chat_stream(sub { print shift->content }, 'Hi');

Synchronous streaming chat. Calls C<$callback> with each chunk.

=cut

# --- Chat with tools ---

sub _gather_tools {
  my ( $self ) = @_;
  my @mcp_servers = @{$self->mcp_servers};
  croak "No MCP servers configured" unless @mcp_servers;

  my ( @all_tools, %tool_server_map );
  for my $mcp (@mcp_servers) {
    my $tools = $mcp->list_tools->get;
    for my $tool (@$tools) {
      $tool_server_map{$tool->{name}} = $mcp;
      push @all_tools, $tool;
    }
  }
  return (\@all_tools, \%tool_server_map);
}

sub _tool_loop_iteration {
  my ( $self, $engine, $conversation, $formatted_tools, $hermes, $hermes_system_msg, $iteration ) = @_;

  # Plugin hook: before LLM call
  $conversation = $self->_run_plugin_before_llm_call($conversation, $iteration)->get;

  # Build and send the request
  my $request;
  if ($hermes) {
    my @conv = ( $hermes_system_msg, @$conversation );
    $request = $engine->chat_request(\@conv, $self->_extra);
  } else {
    $request = $engine->chat_request($conversation, tools => $formatted_tools, $self->_extra);
  }

  my $response = $engine->user_agent->request($request);
  my $data = ref $response eq 'HASH'
    ? $response  # mock: chat_request returns data directly via response_call
    : $engine->parse_response($response);

  # If response_call exists (Langertha::Request::HTTP), use it
  if (ref $request && $request->can('response_call') && $request->response_call) {
    $data = $request->response_call->($response);
  }

  # Plugin hook: after LLM response
  $data = $self->_run_plugin_after_llm_response($data, $iteration)->get;

  return ($conversation, $data);
}

sub simple_chat_with_tools {
  my ( $self, @messages ) = @_;
  my $engine = $self->_assert_chat_engine;
  croak ref($engine) . " does not support tools"
    unless $engine->does('Langertha::Role::Tools');

  my ($all_tools, $tool_server_map) = $self->_gather_tools;
  $log->debugf("[Chat] simple_chat_with_tools via %s, %d tools, max_iterations=%d",
    ref $engine, scalar @$all_tools, $self->tool_max_iterations);
  my $formatted_tools = $engine->format_tools($all_tools);
  my $conversation = $self->_build_messages(@messages);

  my $hermes = $engine->can('hermes_tools') && $engine->hermes_tools;
  my $hermes_system_msg;
  if ($hermes) {
    my $tools_json = $engine->json->encode($formatted_tools);
    my $tool_prompt = sprintf($engine->hermes_tool_prompt, $tools_json);
    $hermes_system_msg = { role => 'system', content => $tool_prompt };
  }

  for my $iteration (1..$self->tool_max_iterations) {
    ($conversation, my $data) = $self->_tool_loop_iteration(
      $engine, $conversation, $formatted_tools, $hermes, $hermes_system_msg, $iteration,
    );

    # Extract tool calls
    my $tool_calls = $hermes
      ? $engine->_hermes_parse_tool_calls($data)
      : $engine->response_tool_calls($data);

    # No tool calls = done
    unless (@$tool_calls) {
      my $text = $hermes
        ? $engine->_hermes_text_content($data)
        : $engine->response_text_content($data);
      if ($engine->think_tag_filter) {
        ($text) = $engine->filter_think_content($text);
      }
      return $text;
    }

    # Execute each tool call
    my @results;
    for my $tc (@$tool_calls) {
      my ( $name, $input ) = $hermes
        ? ( $tc->{name}, $tc->{arguments} )
        : $engine->extract_tool_call($tc);

      $log->debugf("[Chat] Calling tool: %s", $name);

      # Plugin hook: before tool call (can skip)
      my @plugin_tc = $self->_plugin_pipeline_tool_call($name, $input)->get;
      unless (@plugin_tc) {
        push @results, { tool_call => $tc, result => {
          content => [{ type => 'text', text => "Tool call '$name' was skipped by plugin." }],
        }};
        next;
      }
      ( $name, $input ) = @plugin_tc;

      my $mcp = $tool_server_map->{$name}
        or die "Tool '$name' not found on any MCP server";

      my $result = $mcp->call_tool($name, $input)->else(sub {
        my ( $error ) = @_;
        Future->done({
          content => [{ type => 'text', text => "Error calling tool '$name': $error" }],
          isError => JSON::MaybeXS->true,
        });
      })->get;

      # Plugin hook: after tool call
      $result = $self->_run_plugin_after_tool_call($name, $input, $result)->get;

      push @results, { tool_call => $tc, result => $result };
    }

    # Append to conversation
    if ($hermes) {
      push @$conversation, $engine->_hermes_build_tool_results($data, \@results);
    } else {
      push @$conversation, $engine->format_tool_results($data, \@results);
    }
  }

  die "Tool calling loop exceeded " . $self->tool_max_iterations . " iterations";
}

=method simple_chat_with_tools

    my $text = $chat->simple_chat_with_tools(@messages);

Synchronous tool-calling chat loop. Gathers tools from L</mcp_servers>,
sends chat requests, executes tool calls, and iterates until the LLM
returns a final text response. Fires plugin hooks at each step:
C<plugin_before_llm_call>, C<plugin_after_llm_response>,
C<plugin_before_tool_call>, and C<plugin_after_tool_call>.

=cut

async sub simple_chat_with_tools_f {
  my ( $self, @messages ) = @_;
  my $engine = $self->_assert_chat_engine;
  croak ref($engine) . " does not support tools"
    unless $engine->does('Langertha::Role::Tools');

  my ($all_tools, $tool_server_map) = $self->_gather_tools;
  my $formatted_tools = $engine->format_tools($all_tools);
  my $conversation = $self->_build_messages(@messages);

  my $hermes = $engine->can('hermes_tools') && $engine->hermes_tools;
  my $hermes_system_msg;
  if ($hermes) {
    my $tools_json = $engine->json->encode($formatted_tools);
    my $tool_prompt = sprintf($engine->hermes_tool_prompt, $tools_json);
    $hermes_system_msg = { role => 'system', content => $tool_prompt };
  }

  for my $iteration (1..$self->tool_max_iterations) {
    $conversation = await $self->_run_plugin_before_llm_call($conversation, $iteration);

    my $request;
    if ($hermes) {
      my @conv = ( $hermes_system_msg, @$conversation );
      $request = $engine->chat_request(\@conv, $self->_extra);
    } else {
      $request = $engine->chat_request($conversation, tools => $formatted_tools, $self->_extra);
    }

    my $response = await $engine->_async_http->do_request(request => $request);
    unless ($response->is_success) {
      die "" . (ref $engine) . " tool chat request failed: " . $response->status_line;
    }

    my $data = $engine->parse_response($response);
    $data = await $self->_run_plugin_after_llm_response($data, $iteration);

    my $tool_calls = $hermes
      ? $engine->_hermes_parse_tool_calls($data)
      : $engine->response_tool_calls($data);

    unless (@$tool_calls) {
      my $text = $hermes
        ? $engine->_hermes_text_content($data)
        : $engine->response_text_content($data);
      if ($engine->think_tag_filter) {
        ($text) = $engine->filter_think_content($text);
      }
      return $text;
    }

    my @results;
    for my $tc (@$tool_calls) {
      my ( $name, $input ) = $hermes
        ? ( $tc->{name}, $tc->{arguments} )
        : $engine->extract_tool_call($tc);

      my @plugin_tc = await $self->_plugin_pipeline_tool_call($name, $input);
      unless (@plugin_tc) {
        push @results, { tool_call => $tc, result => {
          content => [{ type => 'text', text => "Tool call '$name' was skipped by plugin." }],
        }};
        next;
      }
      ( $name, $input ) = @plugin_tc;

      my $mcp = $tool_server_map->{$name}
        or die "Tool '$name' not found on any MCP server";

      my $result = await $mcp->call_tool($name, $input)->else(sub {
        Future->done({
          content => [{ type => 'text', text => "Error calling tool '$name': $_[0]" }],
          isError => JSON::MaybeXS->true,
        });
      });

      $result = await $self->_run_plugin_after_tool_call($name, $input, $result);
      push @results, { tool_call => $tc, result => $result };
    }

    if ($hermes) {
      push @$conversation, $engine->_hermes_build_tool_results($data, \@results);
    } else {
      push @$conversation, $engine->format_tool_results($data, \@results);
    }
  }

  die "Tool calling loop exceeded " . $self->tool_max_iterations . " iterations";
}

=method simple_chat_with_tools_f

    my $text = await $chat->simple_chat_with_tools_f(@messages);

Async version of L</simple_chat_with_tools>.

=cut

=seealso

=over

=item * L<Langertha::Role::PluginHost> - Plugin system consumed by this class

=item * L<Langertha::Role::Chat> - Chat role required by the engine

=item * L<Langertha::Role::Tools> - Tool-calling role required for MCP methods

=item * L<Langertha::Plugin::Langfuse> - Observability plugin for chat sessions

=item * L<Langertha::Embedder> - Embedding counterpart to this class

=item * L<Langertha::ImageGen> - Image generation counterpart to this class

=item * L<Langertha::Raider> - Autonomous agent with full conversation history

=back

=cut

__PACKAGE__->meta->make_immutable;

1;
