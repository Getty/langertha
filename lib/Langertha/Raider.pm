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

sub clear_history {
  my ( $self ) = @_;
  $self->history([]);
  return $self;
}

=method clear_history

    $raider->clear_history;

Clears conversation history while preserving metrics.

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
    $trace_id = $engine->langfuse_trace(
      name     => 'raid',
      input    => \@messages,
      metadata => {
        mission        => $self->has_mission ? $self->mission : undef,
        history_length => scalar @{$self->history},
      },
    );
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

  # Build new user messages
  my @user_msgs = map {
    ref $_ ? $_ : { role => 'user', content => $_ }
  } @messages;

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

  for my $iteration (1..$self->max_iterations) {
    $raid_iterations++;
    my $iter_t0 = $langfuse ? $engine->_langfuse_timestamp : undef;

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

      # Langfuse: generation for this final iteration
      if ($langfuse) {
        $engine->langfuse_generation(
          trace_id   => $trace_id,
          name       => "raid-iteration-$iteration",
          model      => $engine->chat_model,
          input      => \@conversation,
          output     => $text,
          start_time => $iter_t0,
          end_time   => $engine->_langfuse_timestamp,
          metadata   => { tool_calls => 0 },
        );
      }

      # Persist user messages and final assistant response in history
      push @{$self->history}, @user_msgs;
      push @{$self->history}, { role => 'assistant', content => $text };

      # Update metrics
      my $elapsed = tv_interval($t0) * 1000;
      my $m = $self->metrics;
      $m->{raids}++;
      $m->{iterations}  += $raid_iterations;
      $m->{tool_calls}  += $raid_tool_calls;
      $m->{time_ms}     += $elapsed;

      return $text;
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

      my $result = await $mcp->call_tool($name, $input)->else(sub {
        my ( $error ) = @_;
        Future->done({
          content => [{ type => 'text', text => "Error calling tool '$name': $error" }],
          isError => JSON::MaybeXS->true,
        });
      });

      push @results, { tool_call => $tc, result => $result };
      $raid_tool_calls++;
    }

    # Langfuse: generation for this tool-calling iteration
    if ($langfuse) {
      my @tool_names = map {
        $hermes ? $_->{tool_call}{name} : ($engine->extract_tool_call($_->{tool_call}))[0]
      } @results;
      $engine->langfuse_generation(
        trace_id   => $trace_id,
        name       => "raid-iteration-$iteration",
        model      => $engine->chat_model,
        input      => \@conversation,
        output     => $engine->json->encode([map { $_->{name} } @$tool_calls]),
        start_time => $iter_t0,
        end_time   => $engine->_langfuse_timestamp,
        metadata   => {
          tool_calls => scalar @$tool_calls,
          tools_used => \@tool_names,
        },
      );
    }

    # Append assistant + tool results to conversation (NOT to history)
    if ($hermes) {
      push @conversation, $engine->_hermes_build_tool_results($data, \@results);
    } else {
      push @conversation, $engine->format_tool_results($data, \@results);
    }
  }

  die "Raider tool loop exceeded ".$self->max_iterations." iterations";
}

=method raid_f

    my $response = await $raider->raid_f(@messages);

Async tool-calling conversation. Accepts the same message arguments as
C<simple_chat> (strings become user messages, hashrefs pass through).
Returns a L<Future> resolving to the final text response.

=cut

__PACKAGE__->meta->make_immutable;

1;
