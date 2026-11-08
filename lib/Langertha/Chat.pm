package Langertha::Chat;
# ABSTRACT: Chat abstraction wrapping an engine with optional overrides
our $VERSION = '0.506';
use Moose;
use Future;
use Future::AsyncAwait;
use Carp qw( croak );
use Scalar::Util qw( blessed );
use JSON::MaybeXS;
use Log::Any qw( $log );
use Langertha::Role::Tools ();

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
request in place of the engine's own C<system_prompt>. When not set, the
engine's C<system_prompt> is sent, exactly as the engine's own
C<chat_messages> would send it. System messages the engine itself mandates
still apply either way: with L<Langertha::Engine::NousResearch> and
C<reasoning> enabled, its C<reasoning_prompt> leads the conversation,
followed by this system prompt. Plugins see these system messages in the
conversation passed to C<plugin_before_llm_call>.

=attr model

Optional model name override. When set, it is passed to the engine's request
builder as a per-request C<model> through C<%extra>: it replaces the model in
the request body, or in the URL on engines that name the model there
(L<Langertha::Engine::Gemini>, L<Langertha::Engine::AKI>). It does not change
the engine's C<chat_model>, and every model-scoped decision (capabilities, tool
wire format, reasoning profile, body details) is still taken for
C<chat_model>, as for a C<model> passed to L<Langertha::Role::Chat/chat_f>.
When one of those decisions that the call uses would differ for this model,
each chat call warns once and names the decisions; the request is sent
unchanged. For a different model, use an engine whose C<chat_model> is that
model.

=attr temperature

Optional temperature override. When set, overrides the engine's
temperature.

=attr mcp_servers

ArrayRef of MCP client objects for tool calling — any
L<Net::Async::MCP>-compatible client (for example a L<Net::Async::MCP> client
as used by the langertha-raider distribution). Each must respond to
C<list_tools> and C<call_tool>.

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

# The wrapper's model rides %extra into the engine's request builder past
# chat_f, so the engine's per-request model warning (Role::Chat, karr k352) is
# raised here, once per call, with the request features the call uses: the
# wrapper's temperature, the gathered tools, streaming (karr k360).
sub _warn_model_override {
  my ( $self, $method, $streaming, %request ) = @_;
  return unless $self->has_model;
  my $engine = $self->engine;
  return unless $engine->can('_warn_model_override');
  $engine->_warn_model_override( "Langertha::Chat->$method", { $self->_extra, %request }, $streaming );
  return;
}

# Each message goes through the engine's own per-message step of chat_messages,
# so Langertha::Content objects become the engine's content_format blocks
# (karr k275). The leading system messages are the engine's own
# _system_messages: the engine's system_prompt unless the wrapper has one, plus
# engine prefixes such as NousResearch's reasoning prompt either way (k277).
sub _build_messages {
  my ( $self, @messages ) = @_;
  my $engine    = $self->engine;
  my $normalize = $engine->can('_normalize_content_blocks');
  my @override  = $self->has_system_prompt ? ( $self->system_prompt ) : ();
  return [
    ( $engine->can('_system_messages')
      ? $engine->_system_messages(@override)
      : map { +{ role => 'system', content => $_ } } @override ),
    map {
      my $msg = ref $_ ? $_ : { role => 'user', content => $_ };
      $normalize ? $engine->$normalize($msg) : $msg;
    } @messages
  ];
}

# The _f paths fetch the URL images the engine inlines through its async
# backend before the build, like the engine's own _f paths (karr k274, k275).
async sub _build_messages_f {
  my ( $self, @messages ) = @_;
  my $engine = $self->engine;
  @messages = await $engine->_prefetch_inline_images_f(@messages)
    if $engine->can('_prefetch_inline_images_f');
  return $self->_build_messages(@messages);
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
  my ( $self, $data, $iteration, $call ) = @_;
  for my $plugin (@{$self->_plugin_instances}) {
    $data = await $plugin->plugin_after_llm_response($data, $iteration, $call);
  }
  return $data;
}

# Every plugin hears of the failure, even when one of them dies on it: that
# one is warned about and the next asked. Never fails, so the caller's error
# is the one that propagates.
async sub _run_plugin_llm_call_failed {
  my ( $self, $error, $iteration, $call ) = @_;
  for my $plugin (@{$self->_plugin_instances}) {
    my $future = eval { $plugin->plugin_llm_call_failed($error, $iteration, $call) };
    if ( !defined $future && $@ ) {
      _warn_failed_hook( $plugin, $@ );
      next;
    }
    next unless blessed($future) && $future->isa('Future');
    await $future->else( sub {
      _warn_failed_hook( $plugin, $_[0] );
      Future->done;
    } );
  }
  return;
}

sub _warn_failed_hook {
  my ( $plugin, $error ) = @_;
  my $line = ( split /\n/, ( defined $error ? "$error" : '' ) )[0] // 'unknown error';
  warn ref($plugin) . " died in plugin_llm_call_failed: $line\n";
  return;
}

# One LLM call: $call_f is its Future, from the request to the end of the
# plugin_after_llm_response hooks. When it fails, plugin_llm_call_failed runs
# on every plugin, then the failure propagates unchanged (all of it, a
# Future's category and details included). A cancel is not a failure.
sub _llm_call_f {
  my ( $self, $iteration, $call, $call_f ) = @_;
  return $call_f->else( sub {
    my @failure = @_;
    return $self->_run_plugin_llm_call_failed( $failure[0], $iteration, $call )
      ->then( sub { Future->fail(@failure) } );
  } );
}

# The synchronous counterpart: $code runs the call and returns its result.
sub _llm_call {
  my ( $self, $iteration, $call, $code ) = @_;
  my $result;
  return $result if eval { $result = $code->(); 1 };
  my $error = $@;
  $self->_run_plugin_llm_call_failed( $error, $iteration, $call )->get;
  die $error;
}

# What a streamed call hands plugin_after_llm_response: the stream as one
# Langertha::Response. Observability must never fail the call, so a stream
# that cannot be read into one (a chunk the Response refuses) is passed as
# its text alone.
sub _stream_response {
  my ( $self, $engine, $chunks, $timing ) = @_;
  my $response = eval { $engine->_stream_response( $chunks, $timing ) };
  return $response if $response;
  require Langertha::Response;
  return Langertha::Response->new( content => join( '', map { $_->content } @$chunks ) );
}

# The text a streaming method returns: the content of what the hooks
# returned, so a hook that rewrites the answer rewrites it here too.
sub _stream_text {
  my ( $data, $fallback ) = @_;
  return $data->content if blessed($data) && $data->can('content');
  return $data if defined $data && !ref $data;
  return $fallback;
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
  $self->_warn_model_override( 'simple_chat', 0 );
  my $conversation = $self->_build_messages(@messages);

  $conversation = $self->_run_plugin_before_llm_call($conversation, 1)->get;

  my $call = { stream => 0 };
  return $self->_llm_call( 1, $call, sub {
    my $request = $engine->chat_request($conversation, $self->_extra);
    my $response = $engine->user_agent->request($request);
    $call->{http_response} = $response;
    my $data = $request->response_call->($response);
    return $self->_run_plugin_after_llm_response($data, 1, $call)->get;
  } );
}

=method simple_chat

    my $response = $chat->simple_chat('Hello!');

Sends a synchronous chat request. Fires C<plugin_before_llm_call> and
C<plugin_after_llm_response> hooks (see L</PLUGIN HOOKS>), and
C<plugin_llm_call_failed> when the call fails (see L</FAILED CALLS>).

=cut

# A failed response still updates the engine's rate limit before the die, so
# a caller can back off from a 429 (karr k300); returns the engine's error
# text, the same as its sync croak (karr k312).
sub _failed_message {
  my ( $self, $engine, $response, $what ) = @_;
  $engine->_update_rate_limit($response) if $engine->can('_update_rate_limit');
  return $engine->can('_request_failed_message')
    ? $engine->_request_failed_message( $response, $what )
    : "" . (ref $engine) . " $what failed: " . $response->status_line;
}

async sub simple_chat_f {
  my ( $self, @messages ) = @_;
  my $engine = $self->_assert_chat_engine;
  $self->_warn_model_override( 'simple_chat_f', 0 );
  my $conversation = await $self->_build_messages_f(@messages);

  $conversation = await $self->_run_plugin_before_llm_call($conversation, 1);

  my $call = { stream => 0 };
  return await $self->_llm_call_f( 1, $call,
    $self->_simple_chat_call_f( $engine, $conversation, $call ) );
}

async sub _simple_chat_call_f {
  my ( $self, $engine, $conversation, $call ) = @_;
  my $request = $engine->chat_request($conversation, $self->_extra);
  my $response = await $engine->_async_do_request_f(
    request => $request,
  );
  $call->{http_response} = $response;
  unless ($response->is_success) {
    die $self->_failed_message( $engine, $response, 'request' );
  }
  my $data = $request->response_call->($response);
  return await $self->_run_plugin_after_llm_response($data, 1, $call);
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
  $self->_warn_model_override( 'simple_chat_stream', 1 );
  my $conversation = $self->_build_messages(@messages);

  $conversation = $self->_run_plugin_before_llm_call($conversation, 1)->get;

  my $call = { stream => 1 };
  return $self->_llm_call( 1, $call, sub {
    my $request = $engine->chat_stream_request($conversation, $self->_extra);
    my ( $chunks, $timing ) = $engine->_execute_streaming_request( $request, $callback,
      on_response => sub { $call->{http_response} = $_[0] } );
    my $response = $self->_stream_response( $engine, $chunks, $timing );
    my $data = $self->_run_plugin_after_llm_response($response, 1, $call)->get;
    return _stream_text( $data, $response->content );
  } );
}

=method simple_chat_stream

    my $content = $chat->simple_chat_stream(sub { print shift->content }, 'Hi');

Synchronous streaming chat. Calls C<$callback> with each
L<Langertha::Stream::Chunk> as it is parsed and returns the text of the
answer.

Fires C<plugin_before_llm_call> before the request and, once the stream has
ended, C<plugin_after_llm_response> with the whole stream as one
L<Langertha::Response> (its text, thinking and tool calls, the model and
finish reason the stream named, its usage when the provider sent one, and its
timing) and C<< { stream => 1 } >> as the third argument. The text returned
is the C<content> of what the hooks return, so a hook that rewrites the
answer changes the returned text; the chunks have already gone to
C<$callback>. This method reads the whole response before it parses it, so
the Response carries no C<ttft_seconds>; L</simple_chat_stream_realtime_f>
measures it. A failed call fires C<plugin_llm_call_failed>, see
L</FAILED CALLS>.

=cut

async sub simple_chat_stream_realtime_f {
  my ( $self, $callback, @messages ) = @_;
  my $engine = $self->_assert_chat_engine;
  croak ref($engine) . " does not support streaming"
    unless $engine->can('chat_stream_request');
  croak "simple_chat_stream_realtime_f takes a callback or undef as first argument"
    if defined $callback && ref $callback ne 'CODE';
  $self->_warn_model_override( 'simple_chat_stream_realtime_f', 1 );
  my $conversation = await $self->_build_messages_f(@messages);

  $conversation = await $self->_run_plugin_before_llm_call($conversation, 1);

  my $call = { stream => 1 };
  return await $self->_llm_call_f( 1, $call,
    $self->_stream_call_f( $engine, $conversation, $callback, $call ) );
}

async sub _stream_call_f {
  my ( $self, $engine, $conversation, $callback, $call ) = @_;
  my $request = $engine->chat_stream_request($conversation, $self->_extra);
  my ( $content, $chunks, $timing, $thinking ) = await $engine->_stream_request_realtime_f( $request,
    chunk_callback => $callback,
    on_response    => sub { $call->{http_response} = $_[0] },
  );
  my $response = $self->_stream_response( $engine, $chunks, $timing );
  my $data = await $self->_run_plugin_after_llm_response($response, 1, $call);
  return ( _stream_text( $data, $content ), $chunks, $timing, $thinking );
}

=method simple_chat_stream_realtime_f

    my ( $content, $chunks, $timing, $thinking ) = await $chat->simple_chat_stream_realtime_f(
        sub { print shift->content },
        'Tell me a story',
    );

Async streaming chat: calls C<$callback> (nothing, when it is C<undef>) with
each L<Langertha::Stream::Chunk> as it arrives, and resolves to the same
C<($content, \@chunks, \%timing, $thinking)> as
L<Langertha::Role::Chat/simple_chat_stream_realtime_f>, with C<ttft_seconds>
and C<total_seconds> in C<%timing>. The hooks fire as for
L</simple_chat_stream>; the Response C<plugin_after_llm_response> gets carries
the measured C<ttft_seconds>. C<$content> is the C<content> of what the hooks
return.

=cut

# --- Chat with tools ---

sub _gather_tools {
  my ( $self ) = @_;
  my @mcp_servers = @{$self->mcp_servers};
  croak "No MCP servers configured" unless @mcp_servers;

  # A name two servers offer goes on the wire once, from the first (k332).
  return $self->engine->_tool_loop_tools(
    map { [ $_, $_->list_tools->get ] } @mcp_servers );
}

sub _tool_loop_iteration {
  my ( $self, $engine, $conversation, $formatted_tools, $iteration ) = @_;

  # Plugin hook: before LLM call
  $conversation = $self->_run_plugin_before_llm_call($conversation, $iteration)->get;

  my $call = { stream => 0 };
  my $reply = $self->_llm_call( $iteration, $call, sub {
    # Build and send the request
    my $request = $engine->build_tool_chat_request($conversation, $formatted_tools, $self->_extra);

    my $response = $engine->user_agent->request($request);
    $call->{http_response} = $response;
    # The same failure text and rate-limit update as the async loop (karr k312).
    die $self->_failed_message( $engine, $response, 'tool chat request' )
      unless $response->is_success;

    return $self->_tool_loop_reply_f( $engine, $response, $iteration, $call )->get;
  } );

  return ($conversation, $reply->raw, $reply);
}

# One tool-loop turn's reply. plugin_after_llm_response gets the RAW decoded
# wire body -- the provider's own block list, never the flattened Response
# (karr #81) -- and the body the hooks return is read by the parser chat_f
# uses (karr k321, k322): an error-in-body 200 croaks as it does there, the
# final text is chat_f's, the calls to run are Response.tool_calls (ADR 0003).
# The assistant echo is built from ->raw of that same reply, so a hook that
# drops a call, changes its arguments or rewrites the text is honoured by all
# three, and every echoed call gets exactly one result -- karr k347.
async sub _tool_loop_reply_f {
  my ( $self, $engine, $response, $iteration, $call ) = @_;
  my $data = $engine->parse_response($response);
  $data = await $self->_run_plugin_after_llm_response($data, $iteration, $call);
  return $engine->tool_loop_response($data);
}

# One async tool-loop LLM call: the request, the failure check and the reply.
async sub _tool_loop_call_f {
  my ( $self, $engine, $conversation, $formatted_tools, $iteration, $call ) = @_;
  my $request = $engine->build_tool_chat_request($conversation, $formatted_tools, $self->_extra);

  my $response = await $engine->_async_do_request_f(request => $request);
  $call->{http_response} = $response;
  unless ($response->is_success) {
    die $self->_failed_message( $engine, $response, 'tool chat request' );
  }

  # As the sync loop: the raw body to the hook, chat_f's parser on what it
  # returns, calls, text and echo from that one reply (k321, k322, k347).
  return await $self->_tool_loop_reply_f( $engine, $response, $iteration, $call );
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
  $self->_warn_model_override( 'simple_chat_with_tools', 0, tools => $formatted_tools );
  my $conversation = $self->_build_messages(@messages);

  for my $iteration (1..$self->tool_max_iterations) {
    ($conversation, my $data, my $reply) =$self->_tool_loop_iteration(
      $engine, $conversation, $formatted_tools, $iteration,
    );

    # Calls cut off by the token limit are dropped, as in chat_with_tools_f (k324).
    ( my $calls, $data ) = $engine->tool_loop_calls( $reply, $reply->raw );
    my @tool_calls = @$calls;
    return $reply->content unless @tool_calls;

    # Execute each tool call
    my @results;
    for my $tc (@tool_calls) {
      my ( $name, $input ) = ( $tc->name, $tc->arguments );

      # Arguments that do not decode are answered with an error result
      # before any plugin sees the call (k345).
      if ( my $bad = Langertha::Role::Tools::_undecodable_arguments_result($tc) ) {
        push @results, { tool_call => $tc, result => $bad };
        next;
      }

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

      # The plugins see every call and may rename one onto a real tool; a
      # name no server offers after them is answered with an error result,
      # so the batch runs to the end and the model can correct itself
      # (k332, k348).
      my $mcp = $tool_server_map->{$name};
      unless ($mcp) {
        push @results, { tool_call => $tc,
          result => Langertha::Role::Tools::_unknown_tool_result($name) };
        next;
      }

      my $result = $mcp->call_tool($name, $input)->else(sub {
        my ( $error ) = @_;
        Future->done({
          content => [{ type => 'text', text => "Error calling tool '$name': $error" }],
          isError => JSON->true,
        });
      })->get;

      # Plugin hook: after tool call
      $result = $self->_run_plugin_after_tool_call($name, $input, $result)->get;

      push @results, { tool_call => $tc, result => $result };
    }

    push @$conversation, $engine->format_tool_results($data, \@results);
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

Each reply is read by the engine's C<chat_response>, as in
L<Langertha::Role::Chat/chat_f>: a response whose body reports an error fails
with the same text, the final text is the reply's C<content>, and the calls
run are its L<Langertha::Response/tool_calls>. C<plugin_after_llm_response>
receives the raw decoded wire body before it is read, and the body it returns
is what the turn is read from: the calls run, the final text and the
assistant turn echoed back to the provider all follow its edits, so a call a
plugin removes is neither run nor echoed. A failed request dies with
C<tool chat request failed>, in the sync and the async loop alike. A call
whose arguments were cut off by the token limit is not run, a call whose
arguments otherwise do not decode is answered with an error result, a call to an
unknown tool is answered with an error result, and a tool name two servers
offer runs on the first, and a blocked prompt dies with C<prompt blocked>, as
in L<Langertha::Role::Tools/chat_with_tools_f>. Whether a tool is unknown is
decided on the name C<plugin_before_tool_call> returns: every call reaches the
plugins, and one may map a hallucinated name onto a real tool.

=cut

async sub simple_chat_with_tools_f {
  my ( $self, @messages ) = @_;
  my $engine = $self->_assert_chat_engine;
  croak ref($engine) . " does not support tools"
    unless $engine->does('Langertha::Role::Tools');

  my ($all_tools, $tool_server_map) = $self->_gather_tools;
  my $formatted_tools = $engine->format_tools($all_tools);
  $self->_warn_model_override( 'simple_chat_with_tools_f', 0, tools => $formatted_tools );
  my $conversation = await $self->_build_messages_f(@messages);

  for my $iteration (1..$self->tool_max_iterations) {
    $conversation = await $self->_run_plugin_before_llm_call($conversation, $iteration);

    my $call = { stream => 0 };
    my $reply = await $self->_llm_call_f( $iteration, $call,
      $self->_tool_loop_call_f( $engine, $conversation, $formatted_tools, $iteration, $call ) );

    my ( $calls, $data ) = $engine->tool_loop_calls( $reply, $reply->raw );
    my @tool_calls = @$calls;
    return $reply->content unless @tool_calls;

    my @results;
    for my $tc (@tool_calls) {
      my ( $name, $input ) = ( $tc->name, $tc->arguments );

      # Arguments that do not decode are answered with an error result
      # before any plugin sees the call (k345).
      if ( my $bad = Langertha::Role::Tools::_undecodable_arguments_result($tc) ) {
        push @results, { tool_call => $tc, result => $bad };
        next;
      }

      my @plugin_tc = await $self->_plugin_pipeline_tool_call($name, $input);
      unless (@plugin_tc) {
        push @results, { tool_call => $tc, result => {
          content => [{ type => 'text', text => "Tool call '$name' was skipped by plugin." }],
        }};
        next;
      }
      ( $name, $input ) = @plugin_tc;

      # The plugins see every call and may rename one onto a real tool; a
      # name no server offers after them is answered with an error result,
      # so the batch runs to the end and the model can correct itself
      # (k332, k348).
      my $mcp = $tool_server_map->{$name};
      unless ($mcp) {
        push @results, { tool_call => $tc,
          result => Langertha::Role::Tools::_unknown_tool_result($name) };
        next;
      }

      my $result = await $mcp->call_tool($name, $input)->else(sub {
        Future->done({
          content => [{ type => 'text', text => "Error calling tool '$name': $_[0]" }],
          isError => JSON->true,
        });
      });

      $result = await $self->_run_plugin_after_tool_call($name, $input, $result);
      push @results, { tool_call => $tc, result => $result };
    }

    push @$conversation, $engine->format_tool_results($data, \@results);
  }

  die "Tool calling loop exceeded " . $self->tool_max_iterations . " iterations";
}

=method simple_chat_with_tools_f

    my $text = await $chat->simple_chat_with_tools_f(@messages);

Async version of L</simple_chat_with_tools>.

=cut

=head1 PLUGIN HOOKS

Every chat method passes C<plugin_after_llm_response> a third argument, a
HashRef describing the call: C<stream> is true for L</simple_chat_stream> and
L</simple_chat_stream_realtime_f>, false otherwise, and C<http_response> is
the L<HTTP::Response> the server answered with (on
L</simple_chat_stream_realtime_f> without the streamed body).

=head1 FAILED CALLS

When an LLM call fails -- the request cannot be sent, the server answers
with an error status, the answer cannot be read or reports an error, the
stream breaks or a C<$callback> dies, or a C<plugin_after_llm_response> hook
dies -- every plugin's C<plugin_llm_call_failed> runs with the error, the
iteration and the same HashRef as above (with C<http_response> when the
server answered), before the error reaches the caller. The caller gets the
error unchanged: the same exception, and on the C<_f> methods the same failed
Future, category and details included. A plugin that dies in
C<plugin_llm_call_failed> is warned about and does not replace the error;
the other plugins still run. A plugin that dies in C<plugin_before_llm_call>
or in a tool hook is not a failed LLM call.

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
