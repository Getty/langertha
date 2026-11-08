package Langertha::Plugin;
# ABSTRACT: Base class for plugins
our $VERSION = '0.506';
use Moose;
use Future::AsyncAwait;

=head1 SYNOPSIS

    package Langertha::Plugin::MyPlugin;
    use Moose;
    use Future::AsyncAwait;
    extends 'Langertha::Plugin';

    has my_option => (is => 'ro', default => 42);

    async sub plugin_before_llm_call {
        my ($self, $conversation, $iteration) = @_;
        # ... modify conversation ...
        return $conversation;
    }

    __PACKAGE__->meta->make_immutable;

    # Or with sugar:
    package Langertha::Plugin::MyPlugin;
    use Langertha qw( Plugin );

    has my_option => (is => 'ro', default => 42);

    async sub plugin_before_llm_call { ... }

    __PACKAGE__->meta->make_immutable;

=head1 DESCRIPTION

Base class for Langertha plugins. Plugins are Moose classes that extend
C<Langertha::Plugin> and override hook methods. Plugins can be attached to
any plugin host — a wrapper class such as L<Langertha::Chat>,
L<Langertha::Embedder> or L<Langertha::ImageGen>, an engine that consumes
L<Langertha::Role::PluginHost>, or L<Langertha::Raider> from the
C<langertha-raider> distribution.

Plugins are registered via the C<plugins> attribute on the host:

    my $chat = Langertha::Chat->new(
        engine  => $engine,
        plugins => ['Langfuse', 'MyPlugin'],
    );

Short names are resolved first to C<Langertha::Plugin::$name>, then to
C<LangerthaX::Plugin::$name>. Fully qualified names (containing C<::>)
are used as-is.

=head1 HOOK METHODS

Override these in your subclass. All hooks are C<async sub> and form a
pipeline: the host calls each plugin's hook in order, passing the
return value of one as input to the next.

=over 4

=item B<plugin_before_raid>($messages) -> $messages

Transform input messages before the raid starts.

=item B<plugin_build_conversation>($conversation) -> $conversation

Transform the assembled conversation (mission + history + messages).

=item B<plugin_before_llm_call>($conversation, $iteration) -> $conversation

Transform the conversation before each LLM request.

=item B<plugin_after_llm_response>($data, $iteration, $call?) -> $data

Inspect or transform the parsed LLM response. C<$call> is a HashRef about the
call, passed by L<Langertha::Chat> (see L<Langertha::Chat/PLUGIN HOOKS>): its
C<stream> is true when the answer was streamed. A streamed answer reaches this
hook once the stream has ended, as one L<Langertha::Response> built from the
chunks (text, thinking, tool calls, model, finish reason, usage when the
provider sent one, and timing, with C<ttft_seconds> when the host measured
it); its chunks have already gone to the caller's callback, so a change made
here only reaches the text the streaming method returns. A host that passes
no C<$call> (such as L<Langertha::Raider>) means a call that was not
streamed.

=item B<plugin_llm_call_failed>($error, $iteration, $call?)

Observe an LLM call that failed after C<plugin_before_llm_call> and before
this plugin's own C<plugin_after_llm_response> finished for it: that hook is
then not called, or did not finish. Each plugin hears of a call once, from
one of the two hooks: a plugin whose C<plugin_after_llm_response> already
finished is not called here, even when a later plugin's after-hook then dies
and fails the call for the caller. C<$error> is the exception, as the caller
will get it: usually an error message, which can quote the provider's answer
and with it parts of the prompt. C<$call> is the HashRef described above; its
C<http_response> is the L<HTTP::Response> when the server answered. The
return value is ignored (a Future is waited for, a cancelled one counts as
finished), and the error reaches the caller unchanged after the plugins have
run this hook: a plugin that dies here is warned about, never replaces the
error. The default does nothing. Fired by L<Langertha::Chat> (see
L<Langertha::Chat/FAILED CALLS>).

=item B<plugin_before_tool_call>($name, $input, $call?) -> ($name, $input) or ()

Inspect or transform before each tool execution. Return an empty list
to skip the tool call. C<$call> is a HashRef about the tool call, passed by
L<Langertha::Chat>: its C<id> is the tool call id the model sent (an empty
string when the provider sends none). Every plugin gets the same HashRef,
whatever the plugins before it returned; it is not part of the return value.
A host that passes no C<$call> (such as L<Langertha::Raider>) calls the hook
with two arguments.

=item B<plugin_after_tool_call>($name, $input, $result, $call?) -> $result

Transform the tool result after execution. C<$call> is the same HashRef
C<plugin_before_tool_call> got for this tool call, so a plugin can pair the
two hooks by it even when a later plugin renamed the call or skipped another
one with the same name and arguments. A skipped call never reaches this
hook.

=item B<plugin_after_raid>($result) -> $result

Transform the final L<Langertha::Raider::Result> before return.

=item B<plugin_before_embedding>($text) -> $text

Transform the input before an embedding request (L<Langertha::Embedder>).

=item B<plugin_after_embedding>($text, $vector, $call_result?) -> $vector

Inspect or transform the embedding. C<$call_result> is passed only when the
call went through L<Langertha::Embedder/simple_embedding_result> (or its
C<_f>): the L<Langertha::CallResult> of the request, with its C<usage>,
C<rate_limit>, C<model> and C<total_seconds>. Every hook gets the same
object, whose C<value> is the engine's vector before any hook ran; the
return value of one hook is the C<$vector> of the next. A hook written for
two arguments keeps working.

=item B<plugin_before_image_gen>($prompt) -> $prompt

Transform the prompt before an image generation request (L<Langertha::ImageGen>).

=item B<plugin_after_image_gen>($prompt, $result, $call_result?) -> $result

Inspect or transform the generated images. C<$call_result> is passed only
when the call went through L<Langertha::ImageGen/simple_image_result> (or its
C<_f>), with the same meaning as for C<plugin_after_embedding>.

=back

=cut

has host => (
  is       => 'ro',
  weak_ref => 1,
  required => 1,
);

=attr host

Back-reference to the plugin host (L<Langertha::Raider> or engine)
this plugin belongs to. Weakened to avoid circular references.

=cut

around BUILDARGS => sub {
  my ( $orig, $class, @args ) = @_;
  # Let Moose normalize first: new() also takes one HashRef.
  my $args = $class->$orig(@args);
  if ($args->{raider} && !$args->{host}) {
    $args->{host} = delete $args->{raider};
  }
  return $args;
};

sub raider {
  my ( $self ) = @_;
  my $host = $self->host;
  return $host if $host->isa('Langertha::Raider');
  return undef;
}

=method raider

Convenience accessor. Returns the host if it is a L<Langertha::Raider>,
C<undef> otherwise.

=cut

# --- Hook methods (identity/passthrough defaults) ---

async sub plugin_before_raid {
  my ( $self, $messages ) = @_;
  return $messages;
}

async sub plugin_build_conversation {
  my ( $self, $conversation ) = @_;
  return $conversation;
}

async sub plugin_before_llm_call {
  my ( $self, $conversation, $iteration ) = @_;
  return $conversation;
}

async sub plugin_after_llm_response {
  my ( $self, $data, $iteration, $call ) = @_;
  return $data;
}

async sub plugin_llm_call_failed {
  my ( $self, $error, $iteration, $call ) = @_;
  return;
}

async sub plugin_before_tool_call {
  my ( $self, $name, $input, $call ) = @_;
  return ($name, $input);
}

async sub plugin_after_tool_call {
  my ( $self, $name, $input, $result, $call ) = @_;
  return $result;
}

async sub plugin_after_raid {
  my ( $self, $result ) = @_;
  return $result;
}

=method self_tools

    sub self_tools {
        return [{
            name        => 'my_tool',
            description => 'Does something useful',
            inputSchema => { type => 'object', properties => { ... } },
            code        => sub { $_[0]->text_result('done') },
        }];
    }

Override to register additional self-tools on the host. Returns an
arrayref of tool definitions in MCP format. Tool codes receive
C<($mcp_tool, $args)>.

=cut

sub self_tools { [] }

=method provides_events

    sub provides_events { ['history_saved', 'history_compressed'] }

Override to declare custom events this plugin provides. Other plugins
can hook into these events by implementing C<on_$event_name> methods.
The host validates at instantiation that all required events are
provided.

=cut

sub provides_events { [] }

=method requires_events

    sub requires_events { ['history_saved'] }

Override to declare events this plugin depends on. If no loaded plugin
provides a required event, the host dies with a useful error at
instantiation.

=cut

sub requires_events { [] }

__PACKAGE__->meta->make_immutable;

1;
