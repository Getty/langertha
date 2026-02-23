package Langertha::Raider;
# ABSTRACT: Autonomous agent with conversation history and MCP tools
our $VERSION = '0.201';
use Moose;
use Future::AsyncAwait;
use Time::HiRes qw( gettimeofday tv_interval );
use Carp qw( croak );

=head1 SYNOPSIS

    use IO::Async::Loop;
    use Future::AsyncAwait;
    use Net::Async::MCP;
    use MCP::Server;
    use Langertha::Engine::Anthropic;
    use Langertha::Raider;

    # Set up MCP server with tools
    my $server = MCP::Server->new(name => 'demo', version => '1.0');
    $server->tool(
        name => 'list_files',
        description => 'List files in a directory',
        input_schema => {
            type => 'object',
            properties => { path => { type => 'string' } },
            required => ['path'],
        },
        code => sub { $_[0]->text_result(join("\n", glob("$_[1]->{path}/*"))) },
    );

    my $loop = IO::Async::Loop->new;
    my $mcp = Net::Async::MCP->new(server => $server);
    $loop->add($mcp);

    async sub main {
        await $mcp->initialize;

        my $engine = Langertha::Engine::Anthropic->new(
            api_key     => $ENV{ANTHROPIC_API_KEY},
            mcp_servers => [$mcp],
        );

        my $raider = Langertha::Raider->new(
            engine  => $engine,
            mission => 'You are a code explorer. Investigate files thoroughly.',
        );

        # First raid — uses tools, builds history
        my $r1 = await $raider->raid_f('What files are in the current directory?');
        say $r1;

        # Second raid — has context from first conversation
        my $r2 = await $raider->raid_f('Tell me more about the first file you found.');
        say $r2;

        # Check metrics
        my $m = $raider->metrics;
        say "Raids: $m->{raids}, Tool calls: $m->{tool_calls}, Time: $m->{time_ms}ms";

        # Reset for a fresh conversation
        $raider->clear_history;
    }

    main()->get;

=head1 DESCRIPTION

Langertha::Raider is an autonomous agent that wraps a Langertha engine
with MCP tools. It maintains conversation history across multiple
interactions (raids), enabling multi-turn conversations where the LLM
can reference prior context.

B<Key features:>

=over 4

=item * Conversation history persisted across raids

=item * Mission (system prompt) separate from engine's system_prompt

=item * Automatic MCP tool calling loop

=item * Cumulative metrics tracking

=item * Hermes tool calling support (inherited from engine)

=item * Mid-raid context injection via C<inject()> and C<on_iteration>

=back

B<History management:> Only user messages and final assistant text
responses are persisted in history. Intermediate tool-call messages
(assistant tool requests and tool results) are NOT persisted, preventing
token bloat across long conversations.

=cut

has engine => (
  is => 'ro',
  required => 1,
);

=attr engine

Required. A Langertha engine instance with MCP servers configured.
The engine must compose L<Langertha::Role::Tools>.

=cut

has mission => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_mission',
);

=attr mission

Optional system prompt for the Raider. This is separate from the
engine's own C<system_prompt> — the Raider's mission takes precedence
and is prepended to every conversation.

=cut

has history => (
  is => 'rw',
  isa => 'ArrayRef',
  default => sub { [] },
);

=attr history

ArrayRef of message hashes representing the conversation history.
Automatically managed by C<raid>/C<raid_f>. Can be inspected or
manually set.

=cut

has max_iterations => (
  is => 'ro',
  isa => 'Int',
  default => 10,
);

=attr max_iterations

Maximum number of tool-calling round trips per raid. Defaults to C<10>.

=cut

has max_context_tokens => (
  is => 'ro',
  isa => 'Int',
  predicate => 'has_max_context_tokens',
);

=attr max_context_tokens

Optional. Enables auto-compression when set. When prompt token usage
exceeds C<context_compress_threshold * max_context_tokens>, the working
history is summarized via LLM before the next raid.

=cut

has context_compress_threshold => (
  is => 'ro',
  isa => 'Num',
  default => 0.75,
);

=attr context_compress_threshold

Fraction of C<max_context_tokens> that triggers compression. Defaults
to C<0.75> (75%).

=cut

has compression_prompt => (
  is => 'ro',
  isa => 'Str',
  lazy => 1,
  default => sub {
    'You are a conversation summarizer. Summarize the following conversation '
    . 'between a user and an AI assistant. Preserve all key facts, decisions, '
    . 'action items, file names, code references, and important context. '
    . 'Be concise but complete. The summary will replace the conversation '
    . 'history, so the assistant must be able to continue naturally.'
  },
);

=attr compression_prompt

System prompt used for history summarization. Customizable. The default
instructs the LLM to preserve key facts, decisions, and context.

=cut

has compression_engine => (
  is => 'ro',
  predicate => 'has_compression_engine',
);

=attr compression_engine

Optional separate engine for compression (e.g. a cheaper model).
Falls back to C<engine> when not set.

=cut

has session_history => (
  is => 'ro',
  isa => 'ArrayRef',
  default => sub { [] },
);

=attr session_history

Full chronological archive of ALL messages including tool calls and
results. Never auto-compressed. Persists across C<clear_history> and
C<reset>. Only cleared manually via C<< $raider->session_history([]) >>.

=cut

has _last_prompt_tokens => (
  is => 'rw',
  isa => 'Int',
  predicate => 'has_last_prompt_tokens',
);

has _injections => (
  is => 'ro',
  isa => 'ArrayRef',
  default => sub { [] },
);

has on_iteration => (
  is => 'rw',
  isa => 'CodeRef',
  predicate => 'has_on_iteration',
);

=attr on_iteration

Optional CodeRef called before each LLM call (iterations 2+). Receives
C<($raider, $iteration)> and returns an arrayref of messages to inject,
or undef/empty to skip.

    my $raider = Langertha::Raider->new(
        engine => $engine,
        on_iteration => sub {
            my ($raider, $iteration) = @_;
            return ['Check the error log'] if $iteration == 3;
            return;
        },
    );

=cut

has metrics => (
  is => 'rw',
  isa => 'HashRef',
  default => sub { {
    raids => 0, iterations => 0, tool_calls => 0, time_ms => 0,
  } },
);

=attr metrics

HashRef of cumulative metrics across all raids:

    {
        raids      => 3,       # Number of completed raids
        iterations => 7,       # Total LLM round trips
        tool_calls => 12,      # Total tool invocations
        time_ms    => 4500.2,  # Total wall-clock time in milliseconds
    }

=cut

has langfuse_trace_name => (
  is => 'ro',
  isa => 'Str',
  default => 'raid',
);

=attr langfuse_trace_name

Name for the Langfuse trace created per raid. Defaults to C<'raid'>.

=cut

has langfuse_user_id => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_langfuse_user_id',
);

=attr langfuse_user_id

Optional user ID passed to the Langfuse trace.

=cut

has langfuse_session_id => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_langfuse_session_id',
);

=attr langfuse_session_id

Optional session ID passed to the Langfuse trace. Use this to group
multiple raids into a single Langfuse session.

=cut

has langfuse_tags => (
  is => 'ro',
  isa => 'ArrayRef[Str]',
  predicate => 'has_langfuse_tags',
);

=attr langfuse_tags

Optional tags (ArrayRef[Str]) passed to the Langfuse trace.

=cut

has langfuse_release => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_langfuse_release',
);

=attr langfuse_release

Optional release identifier passed to the Langfuse trace.

=cut

has langfuse_version => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_langfuse_version',
);

=attr langfuse_version

Optional version string passed to the Langfuse trace.

=cut

has langfuse_metadata => (
  is => 'ro',
  isa => 'HashRef',
  predicate => 'has_langfuse_metadata',
);

=attr langfuse_metadata

Optional metadata HashRef merged into the Langfuse trace metadata
(alongside auto-generated fields like mission and history_length).

=cut

sub clear_history {
  my ( $self ) = @_;
  $self->history([]);
  splice @{$self->_injections};
  return $self;
}

=method clear_history

    $raider->clear_history;

Clears conversation history and pending injections while preserving metrics.

=cut

sub inject {
  my ( $self, @messages ) = @_;
  push @{$self->_injections}, @messages;
  return $self;
}

=method inject

    $raider->inject('Also check the test files');
    $raider->inject({ role => 'user', content => 'Focus on .pm files' });

Queues messages to be injected into the conversation at the next iteration.
Strings are automatically wrapped as user messages. The Raider drains the
queue before each LLM call (iterations 2+).

=cut

sub reset {
  my ( $self ) = @_;
  $self->clear_history;
  $self->metrics({
    raids => 0, iterations => 0, tool_calls => 0, time_ms => 0,
  });
  return $self;
}

=method reset

    $raider->reset;

Clears both conversation history and metrics.

=cut

sub _extract_prompt_tokens {
  my ( $self, $data ) = @_;
  # OpenAI-compatible (OpenAI, Groq, Mistral, DeepSeek, MiniMax, vLLM, Ollama, AKI)
  if (my $u = $data->{usage}) {
    return $u->{prompt_tokens} // $u->{input_tokens};
  }
  # Gemini
  if (my $m = $data->{usageMetadata}) {
    return $m->{promptTokenCount};
  }
  return undef;
}

async sub compress_history_f {
  my ( $self ) = @_;
  my @history = @{$self->history};
  return unless @history;

  my $engine = $self->has_compression_engine
    ? $self->compression_engine : $self->engine;

  my @messages = (
    { role => 'system', content => $self->compression_prompt },
    @history,
    { role => 'user', content => 'Provide a concise summary.' },
  );

  my $request = $engine->chat_request(\@messages);
  my $response = await $engine->_async_http->do_request(request => $request);
  my $data = $engine->parse_response($response);
  my $summary = $engine->response_text_content($data);

  # Replace working history with summary
  $self->history([
    { role => 'assistant', content => $summary },
  ]);

  # Mark compression event in session_history
  push @{$self->session_history}, {
    role => 'system',
    content => '[Context compressed — history summarized]',
  };

  return $summary;
}

=method compress_history_f

    my $summary = await $raider->compress_history_f;

Async. Summarizes the current working history via LLM and replaces it
with the summary. Uses C<compression_engine> if set, otherwise falls
back to C<engine>. A marker is added to C<session_history>.

=cut

sub compress_history {
  my ( $self ) = @_;
  return $self->compress_history_f->get;
}

=method compress_history

    my $summary = $raider->compress_history;

Synchronous wrapper around C<compress_history_f>.

=cut

sub register_session_history_tool {
  my ( $self, $server ) = @_;
  $server->tool(
    name => 'session_history',
    description => 'Retrieve the full session history including tool calls.',
    input_schema => {
      type => 'object',
      properties => {
        query   => { type => 'string', description => 'Filter messages containing this text' },
        last_n  => { type => 'integer', description => 'Return only the last N messages' },
      },
    },
    code => sub {
      my ( $tool, $args ) = @_;
      my @hist = @{$self->session_history};
      if (my $q = $args->{query}) {
        @hist = grep { ($_->{content} // '') =~ /\Q$q/i } @hist;
      }
      if (my $n = $args->{last_n}) {
        @hist = @hist[-$n..-1] if @hist > $n;
      }
      my $text = join("\n\n", map {
        "[$_->{role}] $_->{content}"
      } @hist);
      $tool->text_result($text || 'No messages in session history.');
    },
  );
}

=method register_session_history_tool

    $raider->register_session_history_tool($mcp_server);

Registers a C<session_history> MCP tool on the given server, allowing
the LLM to query its own full session history. Supports C<query>
(text filter) and C<last_n> (return last N messages) parameters.

=cut

sub _langfuse_model_parameters {
  my ( $self ) = @_;
  my $e = $self->engine;
  my %p;
  $p{temperature} = $e->temperature if $e->can('has_temperature') && $e->has_temperature;
  $p{max_tokens} = $e->get_response_size if $e->can('get_response_size') && $e->get_response_size;
  return keys %p ? \%p : undef;
}

sub _langfuse_usage {
  my ( $self, $data ) = @_;
  # OpenAI-compatible + Anthropic (both use $data->{usage})
  if (my $u = $data->{usage}) {
    my $input  = $u->{prompt_tokens} // $u->{input_tokens};
    my $output = $u->{completion_tokens} // $u->{output_tokens};
    return {
      input  => $input,
      output => $output,
      total  => $u->{total_tokens} // (($input // 0) + ($output // 0)),
    };
  }
  # Gemini
  if (my $m = $data->{usageMetadata}) {
    return {
      input  => $m->{promptTokenCount},
      output => $m->{candidatesTokenCount},
      total  => $m->{totalTokenCount},
    };
  }
  return undef;
}

sub raid {
  my ( $self, @messages ) = @_;
  return $self->raid_f(@messages)->get;
}

=method raid

    my $response = $raider->raid(@messages);

Synchronous wrapper around C<raid_f>. Sends messages, runs the tool
loop, and returns the final text response. Updates history and metrics.

=cut

async sub raid_f {
  my ( $self, @messages ) = @_;
  my $engine = $self->engine;
  my $t0 = [gettimeofday];
  my $langfuse = $engine->can('langfuse_enabled') && $engine->langfuse_enabled;
  my $trace_id;

  if ($langfuse) {
    my %trace_meta = (
      mission        => $self->has_mission ? $self->mission : undef,
      history_length => scalar @{$self->history},
    );
    if ($self->has_langfuse_metadata) {
      %trace_meta = (%trace_meta, %{$self->langfuse_metadata});
    }
    $trace_id = $engine->langfuse_trace(
      name     => $self->langfuse_trace_name,
      input    => \@messages,
      metadata => \%trace_meta,
      $self->has_langfuse_user_id    ? ( user_id    => $self->langfuse_user_id )    : (),
      $self->has_langfuse_session_id ? ( session_id => $self->langfuse_session_id ) : (),
      $self->has_langfuse_tags       ? ( tags       => $self->langfuse_tags )       : (),
      $self->has_langfuse_release    ? ( release    => $self->langfuse_release )    : (),
      $self->has_langfuse_version    ? ( version    => $self->langfuse_version )    : (),
    );
  }

  # Auto-compress if threshold exceeded
  if ($self->has_max_context_tokens && $self->has_last_prompt_tokens
      && $self->_last_prompt_tokens > $self->max_context_tokens * $self->context_compress_threshold) {
    await $self->compress_history_f();
  }

  croak "Engine must have MCP servers configured"
    unless $engine->can('mcp_servers') && @{$engine->mcp_servers};

  # Gather tools from all MCP servers
  my ( @all_tools, %tool_server_map );
  for my $mcp (@{$engine->mcp_servers}) {
    my $tools = await $mcp->list_tools;
    for my $tool (@$tools) {
      $tool_server_map{$tool->{name}} = $mcp;
      push @all_tools, $tool;
    }
  }

  my $formatted_tools = $engine->format_tools(\@all_tools);
  my $model_params = $langfuse ? $self->_langfuse_model_parameters : undef;

  # Build new user messages
  my @user_msgs = map {
    ref $_ ? $_ : { role => 'user', content => $_ }
  } @messages;

  # Push user messages to session_history
  push @{$self->session_history}, @user_msgs;

  # Build full conversation: mission + history + new messages
  my @conversation;
  push @conversation, { role => 'system', content => $self->mission }
    if $self->has_mission;
  push @conversation, @{$self->history};
  push @conversation, @user_msgs;

  # Hermes mode setup
  my $hermes = $engine->can('hermes_tools') && $engine->hermes_tools;
  my $hermes_system_msg;
  if ($hermes) {
    my $tools_json = $engine->json->encode($formatted_tools);
    my $tool_prompt = sprintf($engine->hermes_tool_prompt, $tools_json);
    $hermes_system_msg = { role => 'system', content => $tool_prompt };
  }

  my $raid_iterations = 0;
  my $raid_tool_calls = 0;
  my @injected_history;

  for my $iteration (1..$self->max_iterations) {
    $raid_iterations++;

    # Drain injections for iterations 2+
    if ($iteration > 1) {
      my @injected;
      if (@{$self->_injections}) {
        push @injected, splice @{$self->_injections};
      }
      if ($self->has_on_iteration) {
        my $cb_msgs = $self->on_iteration->($self, $iteration);
        push @injected, @$cb_msgs if $cb_msgs && @$cb_msgs;
      }
      if (@injected) {
        my @msgs = map {
          ref $_ ? $_ : { role => 'user', content => $_ }
        } @injected;
        push @conversation, @msgs;
        push @injected_history, @msgs;
        push @{$self->session_history}, @msgs;
      }
    }

    my $iter_t0 = $langfuse ? $engine->_langfuse_timestamp : undef;

    # Langfuse: create iteration span
    my $iter_span_id;
    if ($langfuse) {
      $iter_span_id = $engine->langfuse_span(
        trace_id   => $trace_id,
        name       => "iteration-$iteration",
        start_time => $iter_t0,
      );
    }

    # Build and send the request
    my $request;
    if ($hermes) {
      my @conv = ( $hermes_system_msg, @conversation );
      $request = $engine->chat_request(\@conv);
    } else {
      $request = $engine->chat_request(\@conversation, tools => $formatted_tools);
    }

    my $response = await $engine->_async_http->do_request(request => $request);

    unless ($response->is_success) {
      die "".(ref $engine)." raid request failed: ".$response->status_line;
    }

    my $data = $engine->parse_response($response);

    # Track prompt tokens for auto-compression
    my $pt = $self->_extract_prompt_tokens($data);
    $self->_last_prompt_tokens($pt) if defined $pt;

    # Extract usage for Langfuse
    my $langfuse_usage = $langfuse ? $self->_langfuse_usage($data) : undef;

    # Extract tool calls
    my $tool_calls;
    if ($hermes) {
      $tool_calls = $engine->_hermes_parse_tool_calls($data);
    } else {
      $tool_calls = $engine->response_tool_calls($data);
    }

    # No tool calls means done — extract final text
    unless (@$tool_calls) {
      my $text;
      if ($hermes) {
        $text = $engine->_hermes_text_content($data);
      } else {
        $text = $engine->response_text_content($data);
      }

      my $iter_t1 = $langfuse ? $engine->_langfuse_timestamp : undef;

      # Langfuse: generation nested under iteration span
      if ($langfuse) {
        $engine->langfuse_generation(
          trace_id              => $trace_id,
          parent_observation_id => $iter_span_id,
          name                  => 'llm-call',
          model                 => $engine->chat_model,
          input                 => \@conversation,
          output                => $text,
          start_time            => $iter_t0,
          end_time              => $iter_t1,
          $langfuse_usage  ? ( usage            => $langfuse_usage )  : (),
          $model_params    ? ( model_parameters => $model_params )    : (),
        );

        # Close iteration span
        $engine->langfuse_update_span(
          id       => $iter_span_id,
          end_time => $iter_t1,
          output   => $text,
        );

        # Update trace with final output
        $engine->langfuse_update_trace(
          id     => $trace_id,
          output => $text,
        );
      }

      # Persist user messages, injections, and final assistant response in history
      push @{$self->history}, @user_msgs;
      push @{$self->history}, @injected_history if @injected_history;
      push @{$self->history}, { role => 'assistant', content => $text };

      # Push final assistant response to session_history
      push @{$self->session_history}, { role => 'assistant', content => $text };

      # Update metrics
      my $elapsed = tv_interval($t0) * 1000;
      my $m = $self->metrics;
      $m->{raids}++;
      $m->{iterations}  += $raid_iterations;
      $m->{tool_calls}  += $raid_tool_calls;
      $m->{time_ms}     += $elapsed;

      return $text;
    }

    # Langfuse: generation for the LLM call that produced tool calls
    my $post_llm_t = $langfuse ? $engine->_langfuse_timestamp : undef;
    if ($langfuse) {
      $engine->langfuse_generation(
        trace_id              => $trace_id,
        parent_observation_id => $iter_span_id,
        name                  => 'llm-call',
        model                 => $engine->chat_model,
        input                 => \@conversation,
        output                => $engine->json->encode([map {
          $hermes ? $_->{name} : ($engine->extract_tool_call($_))[0]
        } @$tool_calls]),
        start_time            => $iter_t0,
        end_time              => $post_llm_t,
        $langfuse_usage  ? ( usage            => $langfuse_usage )  : (),
        $model_params    ? ( model_parameters => $model_params )    : (),
      );
    }

    # Execute each tool call
    my @results;
    for my $tc (@$tool_calls) {
      my ( $name, $input );
      if ($hermes) {
        ( $name, $input ) = ( $tc->{name}, $tc->{arguments} );
      } else {
        ( $name, $input ) = $engine->extract_tool_call($tc);
      }

      my $mcp = $tool_server_map{$name}
        or die "Tool '$name' not found on any MCP server";

      my $tool_t0 = $langfuse ? $engine->_langfuse_timestamp : undef;

      my $result = await $mcp->call_tool($name, $input)->else(sub {
        my ( $error ) = @_;
        Future->done({
          content => [{ type => 'text', text => "Error calling tool '$name': $error" }],
          isError => JSON::MaybeXS->true,
        });
      });

      # Langfuse: span for each tool call, nested under iteration span
      if ($langfuse) {
        my $tool_output = join('', map { $_->{text} // '' } @{$result->{content} // []});
        $engine->langfuse_span(
          trace_id              => $trace_id,
          parent_observation_id => $iter_span_id,
          name                  => "tool: $name",
          input                 => $input,
          output                => $tool_output,
          start_time            => $tool_t0,
          end_time              => $engine->_langfuse_timestamp,
          $result->{isError} ? ( level => 'ERROR' ) : (),
        );
      }

      push @results, { tool_call => $tc, result => $result };
      $raid_tool_calls++;
    }

    # Langfuse: close iteration span after tools complete
    if ($langfuse) {
      $engine->langfuse_update_span(
        id       => $iter_span_id,
        end_time => $engine->_langfuse_timestamp,
        metadata => {
          tool_calls => scalar @$tool_calls,
          tools_used => [map {
            $hermes ? $_->{tool_call}{name} : ($engine->extract_tool_call($_->{tool_call}))[0]
          } @results],
        },
      );
    }

    # Append assistant + tool results to conversation and session_history
    my @tool_msgs;
    if ($hermes) {
      @tool_msgs = $engine->_hermes_build_tool_results($data, \@results);
    } else {
      @tool_msgs = $engine->format_tool_results($data, \@results);
    }
    push @conversation, @tool_msgs;
    push @{$self->session_history}, @tool_msgs;
  }

  die "Raider tool loop exceeded ".$self->max_iterations." iterations";
}

=method raid_f

    my $response = await $raider->raid_f(@messages);

Async tool-calling conversation. Accepts the same message arguments as
C<simple_chat> (strings become user messages, hashrefs pass through).
Returns a L<Future> resolving to the final text response.

=cut

=seealso

=over

=item * L<Langertha::Role::Tools> - Lower-level single-turn tool calling

=item * L<Langertha::Role::Langfuse> - Observability integration (used by Raider)

=item * L<Langertha::Role::SystemPrompt> - Engine-level system prompt (Raider uses C<mission> instead)

=back

=cut

__PACKAGE__->meta->make_immutable;

1;
