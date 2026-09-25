package Langertha::Role::Chat;
# ABSTRACT: Role for APIs with normal chat functionality
our $VERSION = '0.503';
use Moose::Role;
use Future;
use Future::AsyncAwait;
use Carp qw( carp croak );
use JSON::MaybeXS;
use Log::Any qw( $log );
use Scalar::Util qw( blessed );
use Time::HiRes qw( gettimeofday tv_interval );
use Langertha::ToolChoice;
use Langertha::Tool;
use Langertha::Role::Capabilities;

requires qw(
  chat_request
  chat_response
);

=method content_format

    my $fmt = $engine->content_format;  # 'openai' | 'anthropic' | 'gemini'

Wire format for multimodal content blocks. Controls how
L<Langertha::Content> objects embedded in a message's C<content> arrayref
are serialized during L</chat_messages>. Defaults to C<'openai'>; overridden
by L<Langertha::Engine::AnthropicBase> and L<Langertha::Engine::Gemini>.

=cut

# Defaults to the OpenAI dialect; AnthropicBase (via AnthropicCompatible) and
# Engine::Gemini override the builder. The POD =method above documents the
# same override points from the engine-user perspective.
sub content_format { 'openai' }

=method engine_capabilities

    my $caps = $engine->engine_capabilities;
    if ( $caps->{tool_choice_named} ) { ... }

Returns a HashRef of capability flags so callers can avoid passing
parameters the engine cannot honour.

The base implementation reports only what L<Langertha::Role::Chat>
itself provides (C<chat>). Every other capability-bearing role
(L<Langertha::Role::Tools>, L<Langertha::Role::ResponseFormat>,
L<Langertha::Role::Streaming>, L<Langertha::Role::Embedding>,
L<Langertha::Role::Transcription>, L<Langertha::Role::ImageGeneration>,
L<Langertha::Role::HermesTools>, L<Langertha::Role::Temperature>,
L<Langertha::Role::Seed>, L<Langertha::Role::ContextSize>,
L<Langertha::Role::ResponseSize>, L<Langertha::Role::SystemPrompt>,
L<Langertha::Role::ParallelToolUse>) hangs its own contribution into
this method via C<around engine_capabilities>. Engines override (also
via C<around>) when the wire reality differs from the role inventory
— for example to clear C<tool_choice_named> on providers that only
accept string forms.

Common keys produced by the bundled roles:

=over

=item * C<chat> — C<simple_chat>/C<simple_chat_f> work

=item * C<streaming> — C<chat_stream_request> is wired up

=item * C<tools_native> — engine accepts a C<tools> array on the wire

=item * C<tools_hermes> — tools are injected via Hermes-style XML
prompt rather than (or in addition to) the native API

=item * C<tool_choice_auto> / C<tool_choice_any> / C<tool_choice_none> —
which string-form C<tool_choice> values are accepted

=item * C<tool_choice_named> — C<{type =E<gt> 'tool', name =E<gt> '...'}>
forcing works (possibly translated internally — Gemini routes named
tools through C<allowed_function_names>, for example)

=item * C<response_format_json_object> — C<{type =E<gt> 'json_object'}>

=item * C<response_format_json_schema> — JSON Schema structured output

=item * C<embedding>, C<transcription>, C<image_generation> — auxiliary
capabilities matching the corresponding roles

=item * C<temperature>, C<seed>, C<context_size>, C<response_size>,
C<system_prompt>, C<parallel_tool_use> — generation-parameter knobs
the engine will honour

=back

Callers should treat the hash as advisory — a missing key means
"unknown / unsupported", a true value means "the engine claims it
will honour this".

=cut

with 'Langertha::Role::Capabilities';

=head1 SYNOPSIS

    # Synchronous chat
    my $response = $engine->simple_chat('Hello, how are you?');

    # Streaming with callback
    $engine->simple_chat_stream(sub {
        my ($chunk) = @_;
        print $chunk->content;
    }, 'Tell me a story');

    # Streaming with iterator
    my $stream = $engine->simple_chat_stream_iterator('Tell me a story');
    while (my $chunk = $stream->next) {
        print $chunk->content;
    }

    # Async with Future (traditional style)
    my $future = $engine->simple_chat_f('Hello');
    my $response = $future->get;

    # Async with Future::AsyncAwait (recommended)
    use Future::AsyncAwait;

    async sub chat_example {
        my ($engine) = @_;
        my $response = await $engine->simple_chat_f('Hello');
        say $response;
    }

    # Async streaming with real-time callback
    async sub stream_example {
        my ($engine) = @_;
        my ($content, $chunks) = await $engine->simple_chat_stream_realtime_f(
            sub { print shift->content },
            'Tell me a story'
        );
        say "\nTotal chunks: ", scalar @$chunks;
    }

=head1 DESCRIPTION

This role provides chat functionality for LLM engines. It includes both
synchronous and asynchronous (L<Future>-based) methods for chat and streaming.

The Future-based C<_f> methods are implemented using L<Future::AsyncAwait>. The
HTTP backend is selected by L<Langertha::Role::AsyncHTTP>: an injected
C<_async_http> client wins, else L<Net::Async::HTTP> if it can be loaded, else a
synchronous L<LWP::UserAgent> fallback (L<Langertha::Request::SyncHTTP>). These
async modules are loaded lazily only on the async path, so synchronous-only
usage — and the sync fallback — does not require them.

When the sync fallback is used the C<_f> methods still return a L<Future> and
keep working, but they run B<synchronously and sequentially> (blocking, no
concurrency): the future is already complete when returned, so several C<_f>
calls awaited "in parallel" run one after another. Install L<Net::Async::HTTP>
+ L<IO::Async> (or inject your own C<_async_http> client) for real concurrency.

=cut

has chat_model => (
  is => 'ro',
  isa => 'Maybe[Str]',
  lazy_build => 1,
);
sub _build_chat_model {
  my ( $self ) = @_;
  croak "".(ref $self)." can't handle models!" unless $self->does('Langertha::Role::Models');
  return $self->default_chat_model if $self->can('default_chat_model');
  return $self->model;
}

=attr chat_model

The model name used for chat requests. Lazily defaults to C<default_chat_model>
if the engine provides it, otherwise falls back to the general C<model>
attribute from L<Langertha::Role::Models>.

=cut

# Adds a key/value pair into an existing timing hashref (or new one).
# Used to layer client-measured ttft_seconds / total_seconds onto a
# Response that may already carry provider-native stages (e.g. Ollama's
# *_seconds). Never overwrites an existing key — first-write-wins so a
# provider-supplied duration (e.g. Ollama's total_seconds) trumps the
# client measurement.
sub _merge_timing_field {
  my ( $existing, $key, $value ) = @_;
  my $t = $existing ? { %$existing } : {};
  $t->{$key} = $value unless exists $t->{$key};
  return $t;
}

sub chat {
  my ( $self, @messages ) = @_;
  return $self->chat_request($self->chat_messages(@messages));
}

=method chat

    my $request = $engine->chat(@messages);

Builds and returns a chat HTTP request object. Messages may be plain strings
(treated as C<user> role) or HashRefs with C<role> and C<content> keys. A
system prompt from L<Langertha::Role::SystemPrompt> is prepended automatically.

=cut

sub chat_messages {
  my ( $self, @messages ) = @_;
  $self->_warn_control_message_args(@messages);
  my @out;
  push @out, { role => 'system', content => $self->system_prompt }
    if $self->has_system_prompt;
  for my $m (@messages) {
    my $msg = ref $m ? $m : { role => 'user', content => $m };
    push @out, $self->_normalize_content_blocks($msg);
  }
  return \@out;
}

sub _normalize_content_blocks {
  my ( $self, $msg ) = @_;
  my $content = $msg->{content};
  return $msg unless ref $content eq 'ARRAY';

  my $needs_convert = 0;
  for my $b (@$content) {
    if ( blessed($b) && $b->does('Langertha::Content') ) {
      $needs_convert = 1;
      last;
    }
  }
  return $msg unless $needs_convert;

  my $fmt    = $self->content_format;
  my $method = "to_$fmt";

  my @blocks = map {
    if ( blessed($_) && $_->does('Langertha::Content') ) {
      $_->$method;
    }
    elsif ( !ref $_ ) {
      $fmt eq 'gemini'
        ? { text => $_ }
        : { type => 'text', text => $_ };
    }
    else {
      $_;
    }
  } @$content;

  if ( $fmt eq 'gemini' ) {
    my $role = ( $msg->{role} // 'user' ) eq 'assistant' ? 'model' : ( $msg->{role} // 'user' );
    return { role => $role, parts => \@blocks };
  }
  return { %$msg, content => \@blocks };
}

=method chat_messages

    my $messages = $engine->chat_messages(@messages);

Normalises C<@messages> into the canonical ArrayRef-of-HashRef format expected
by C<chat_request>. Plain strings become C<{ role =E<gt> 'user', content =E<gt>
$string }>. If the engine has a C<system_prompt> set it is prepended as a
C<system> message.

=cut

sub simple_chat {
  my ( $self, @messages ) = @_;
  $log->debugf("[%s] simple_chat with %d message(s), model=%s",
    ref $self, scalar @messages, $self->chat_model // 'default');
  my $t0 = [gettimeofday];
  my $request = $self->chat(@messages);
  my $response = $self->user_agent->request($request);
  my $elapsed = tv_interval($t0);
  my $result = $request->response_call->($response);
  if (ref $result && $result->isa('Langertha::Response')) {
    $result = $result->clone_with(
      timing => _merge_timing_field($result->timing, total_seconds => $elapsed),
    );
    if ($self->can('has_rate_limit') && $self->has_rate_limit) {
      $result = $result->clone_with(rate_limit => $self->rate_limit);
    }
  }
  return $result;
}

=method simple_chat

    my $response = $engine->simple_chat(@messages);
    my $response = $engine->simple_chat('Hello, how are you?');

Sends a synchronous chat request and returns the response text. Blocks until
the request completes.

=cut

sub chat_stream {
  my ( $self, @messages ) = @_;
  croak "".(ref $self)." does not support streaming"
    unless $self->can('chat_stream_request');
  return $self->chat_stream_request($self->chat_messages(@messages));
}

=method chat_stream

    my $request = $engine->chat_stream(@messages);

Builds and returns a streaming chat HTTP request object. Croaks if the engine
does not implement C<chat_stream_request>. Use L</simple_chat_stream> or
L</simple_chat_stream_iterator> to execute the request.

=cut

sub simple_chat_stream {
  my ( $self, $callback, @messages ) = @_;
  croak "simple_chat_stream requires a callback as first argument"
    unless ref $callback eq 'CODE';
  $log->debugf("[%s] simple_chat_stream (%s format)", ref $self, $self->stream_format);
  my $request = $self->chat_stream(@messages);
  my ( $chunks, $timing ) = $self->execute_streaming_request($request, $callback);
  $log->debugf("[%s] Stream completed: %d chunks (%.3fs)",
    ref $self, scalar @$chunks, $timing->{total_seconds} // 0);
  my $content  = join('', map { $_->content } @$chunks);
  my $thinking = $self->aggregate_thinking($chunks);
  return wantarray ? ( $content, $thinking ) : $content;
}

=method simple_chat_stream

    my $content = $engine->simple_chat_stream($callback, @messages);

    $engine->simple_chat_stream(sub {
        my ($chunk) = @_;
        print $chunk->content;
    }, 'Tell me a story');

Sends a synchronous streaming chat request. Calls C<$callback> with each
L<Langertha::Stream::Chunk> as it arrives (each chunk may carry incremental
C<thinking>, see L<Langertha::Stream::Chunk/thinking>). In scalar context
returns the complete concatenated content string; in list context returns
C<($content, $thinking)> where C<$thinking> is the aggregated chain-of-thought
(C<undef> when the engine surfaced none), as L</aggregate_thinking> assembles
it. Blocks until the stream completes. C<total_seconds> is logged; for a full
breakdown read L</execute_streaming_request>.

=cut

sub simple_chat_stream_iterator {
  my ( $self, @messages ) = @_;
  require Langertha::Stream;
  my $request = $self->chat_stream(@messages);
  my ( $chunks, $timing ) = $self->execute_streaming_request($request);
  $log->debugf("[%s] Stream completed: %d chunks (%.3fs)",
    ref $self, scalar @$chunks, $timing->{total_seconds} // 0);
  return Langertha::Stream->new(chunks => $chunks);
}

=method simple_chat_stream_iterator

    my $stream = $engine->simple_chat_stream_iterator(@messages);
    while (my $chunk = $stream->next) {
        print $chunk->content;
    }

Returns a L<Langertha::Stream> iterator. The full response is fetched
synchronously and buffered; iteration yields each L<Langertha::Stream::Chunk>
in order.

=cut

# Future-based async methods. The _async_http backend (and its _async_loop)
# come from Langertha::Role::AsyncHTTP (composed below): injected client >
# Net::Async::HTTP > synchronous LWP fallback.

async sub simple_chat_f {
  my ( $self, @messages ) = @_;
  $log->debugf("[%s] simple_chat_f with %d message(s)", ref $self, scalar @messages);
  return await $self->chat_f( messages => \@messages );
}

# Canonical per-request controls (karr #46). chat_f normalizes these like
# messages/tools instead of spreading them as raw target-wire kwargs: each
# engine's chat_request consumes the `controls` hash and places them via the
# same value objects the engine attributes use (Langertha::Reasoning,
# Langertha::PromptCache) or the engine's own placement logic (Ollama options,
# Gemini generationConfig). Unknown keys still pass straight through.
my %CANONICAL_CONTROLS = map { $_ => 1 } qw(
  temperature
  max_tokens
  response_format
  seed
  parallel_tool_use
  reasoning_effort
  thinking_budget
  thinking_display
  prompt_cache
  prompt_cache_ttl
  prompt_cache_key
  prefix_cache_salt
  cache_prompt
  n_cache_reuse
  id_slot
  priority
  return_cached_tokens_details
  extra_key
);

sub _extract_controls {
  my ( $self, $opts ) = @_;
  my %controls;
  for my $key ( keys %CANONICAL_CONTROLS ) {
    $controls{$key} = delete $opts->{$key} if exists $opts->{$key};
  }
  return \%controls;
}

=method _extract_controls

    my $controls = $engine->_extract_controls(\%opts);

Removes the canonical per-request controls (karr #46) from C<%opts> and returns
them as a HashRef. The engine's C<chat_request> receives the hash under the
C<controls> key and places each control on its wire; unknown keys stay in
C<%opts> and pass straight through as before.

=cut

# karr #122: simple_chat / simple_chat_f / chat funnel their positional
# @messages through chat_messages, which turns every non-ref scalar into a
# { role => 'user' } turn. A caller who mistakes those methods for chat_f and
# appends a control as a kwarg tail -- simple_chat($prompt, reasoning_effort =>
# 'high') -- silently sends the control name and its value as extra user
# messages, with no error and no effect (the project hit this twice in its own
# docs). This is a diagnostic only: warn once (never die) when a plain-scalar
# message exactly matches a canonical control name; behaviour is otherwise
# unchanged (the strings still become messages as before). A control name has
# no legitimate use as a whole user turn, so this has no false positives in
# practice. The broader unknown-constructor-arg finding (karr #101) is out of
# scope here.
sub _warn_control_message_args {
  my ( $self, @messages ) = @_;
  my %seen;
  my @hits =
    grep { !$seen{$_}++ }
    grep { defined $_ && !ref $_ && $CANONICAL_CONTROLS{$_} } @messages;
  return unless @hits;
  carp sprintf(
    "%s: message argument(s) %s match a chat_f control name and are being "
      . "sent as plain user message text. Per-request controls such as "
      . "reasoning_effort, temperature and response_format are named "
      . "arguments to chat_f (or engine constructor attributes), not "
      . "simple_chat/chat message arguments.",
    ref $self,
    join( ', ', map { "'$_'" } @hits ),
  );
  return;
}

# karr #148 / #184: a couple of OpenAI-compatible serving stacks reject a
# request that combines tools and a structured-output response_format with an
# opaque HTTP 400 and no body. No boolean capability flag can express a mutual
# exclusion between two capabilities in one request (ADR 0021). The constraint
# is a property of the serving STACK, not of the model: Groq and Cerebras
# enforce it across every model they serve, while AKI serves gpt-oss-120b with
# tools + a json_schema response_format at HTTP 200 (live 2026-09-19) — so each
# affected engine declares its own all-models rule and there is no shared base
# rule to over-fire on the unaffected stacks.
#
# The seam mirrors ADR 0019's model_capability_corrections: an ORDERED list of
# ( $matcher => $rule ) pairs keyed on chat_model. $matcher is an exact
# model-id string (matched with eq) or a qr// regex (matched against
# chat_model). $rule is a CODEREF — the concrete seam, deliberately NOT a
# declarative constraint DSL (karr #148) — invoked as $self->$rule(%request)
# with has_tools / response_format / streaming; it croaks when the request hits
# the combination the stack rejects. The default is an empty list, so engines
# that constrain nothing pay nothing; an engine whose serving stack rejects the
# combination declares an all-models rule by overriding
# model_capability_exclusions (Groq, Cerebras).
sub model_capability_exclusions { return () }

# Consulted by chat_f (streaming => 0) and chat_stream_realtime_f
# (streaming => 1) after the effective post-rewrite request is built (ADR 0021),
# so an ADR 0005 rewrite that already collapsed the body to a single path
# pre-empts it. Walks the per-model exclusion table for the selected chat_model
# and lets each matching rule convert a known provider 400 into a clear local
# croak. A no-op when the table is empty or no matcher hits.
sub _check_capability_exclusions {
  my ( $self, %request ) = @_;
  my @rules = $self->model_capability_exclusions;
  return unless @rules;
  # chat_model is the model that actually carries tools / response_format on the
  # wire; guard for the rare consumer that has no model surface at all.
  my $model = $self->can('chat_model') ? $self->chat_model : undef;
  return unless defined $model && length $model;
  while ( @rules >= 2 ) {
    my ( $matcher, $rule ) = splice @rules, 0, 2;
    my $hit = ref $matcher eq 'Regexp' ? ( $model =~ $matcher )
            :                            ( $model eq $matcher );
    next unless $hit;
    $self->$rule(%request);
  }
  return;
}

=method model_capability_exclusions

    sub model_capability_exclusions {
      return (
        qr/some-family/  => \&_exclude_some_combination,  # a model family (regex)
        'exact-model-id' => \&_exclude_some_combination,  # an exact model id
      );
    }

The per-model capability-exclusion seam (karr #148), consulted at the
C<chat_f> / C<chat_stream_realtime_f> layer above the boolean registry. A
boolean capability flag asserts I<the wire accepts field X>; this seam
expresses a I<mutual exclusion between two fields in one request> — combining
C<tools> with a structured-output C<response_format> — which a flag cannot spell
(L<ADR 0021|docs/adr/0021-pairwise-capability-exclusions-as-per-engine-guard.md>).

Returns an B<ordered> list of C<< ( $matcher => $rule ) >> pairs, keyed on
C<chat_model> exactly as L<Langertha::Role::Capabilities/model_capability_corrections>
is. C<$matcher> is an exact model-id string (matched with C<eq>) or a C<qr//>
regex (matched against C<chat_model>) — model ids come in families and, through
aggregators, carry a C<provider/> prefix, so a regex catches the routed backend
id too. C<$rule> is a B<coderef> (the concrete seam — deliberately not a
constraint DSL) invoked as C<< $self->$rule(%request) >> with C<has_tools>,
C<response_format> and C<streaming>; it C<croak>s when the request hits the
combination the model rejects.

Where the rule lives depends on what the constraint belongs to. Groq and
Cerebras reject C<tools> alongside a structured-output C<response_format> across
every model they serve — a property of the serving stack — so each declares an
all-models (C<qr//>) rule by overriding this method. A constraint that belonged
to one model would instead be keyed on that model id or family regex, leaving a
sibling model on the same engine unaffected. The default is an empty list, so an
engine that constrains nothing pays nothing.

=cut

# True when the request asks for tools — either a tools array or a
# forced named tool_choice. Used to feed the capability-exclusion hook.
sub _chat_tools_requested {
  my ( $self, $opts ) = @_;
  # An empty tools => [] sends zero tools on the wire, so it must NOT trip the
  # capability-exclusion guard (which would croak on Cerebras/Groq for a request
  # that combines tools with a structured-output response_format). Only a
  # non-empty tools array counts as "tools requested" here.
  return 1 if ref $opts->{tools} eq 'ARRAY' && @{ $opts->{tools} };
  return 0 unless exists $opts->{tool_choice};
  my $tc = Langertha::ToolChoice->from_hash( $opts->{tool_choice} );
  return ( $tc && $tc->type eq 'tool' ) ? 1 : 0;
}

async sub chat_f {
  my ( $self, %opts ) = @_;

  my $messages = delete $opts{messages} // [];
  my @messages = ref $messages eq 'ARRAY' ? @$messages : ($messages);

  # Auto-fallback: forced named tool on an engine that cannot do
  # native named-tool-forcing but supports json_schema response_format.
  # Rewrite tools+tool_choice into a response_format and remember the
  # tool name so we can synthesize a tool_calls entry afterwards.
  my $synth_tool_name;
  if ( exists $opts{tool_choice}
    && exists $opts{tools}
    && !$self->supports('tool_choice_named')
    && $self->supports('response_format_json_schema')
  ) {
    my $tc = Langertha::ToolChoice->from_hash( $opts{tool_choice} );
    if ( $tc && $tc->type eq 'tool' && defined $tc->name && length $tc->name ) {
      my $name = $tc->name;
      my ($tool) =
        grep { defined $_ && $_->name eq $name }
        map  { Langertha::Tool->from_hash($_) }
        @{ $opts{tools} };
      if ($tool) {
        delete $opts{tools};
        delete $opts{tool_choice};
        $opts{response_format} = {
          type        => 'json_schema',
          json_schema => {
            %{ $tool->to_json_schema },
            strict => JSON->true,
          },
        };
        $synth_tool_name = $name;
        $log->debugf("[%s] forced-tool fallback: tool '%s' rerouted via response_format",
          ref $self, $name);
      }
    }
  }

  # Provider mutual-exclusion guard (karr #148). Consulted after the
  # forced-tool fallback (which may have set response_format) so it sees the
  # effective request; walks the per-model exclusion table for the selected
  # chat_model and croaks on a combination the model rejects with an opaque 400.
  $self->_check_capability_exclusions(
    has_tools       => $self->_chat_tools_requested(\%opts),
    response_format => $opts{response_format},
    streaming       => 0,
  );

  # Extract the canonical controls (after the forced-tool fallback, which may
  # have set response_format) and hand them to chat_request under `controls`.
  my $controls = $self->_extract_controls(\%opts);

  my $t0 = [gettimeofday];
  my $request = $self->chat_request( $self->chat_messages(@messages),
    ( %$controls ? ( controls => $controls ) : () ),
    %opts );

  my $response = await $self->_async_http->do_request( request => $request );

  unless ($response->is_success) {
    die "".(ref $self)." request failed: ".$response->status_line;
  }

  my $elapsed = tv_interval($t0);
  my $result = $request->response_call->($response);

  if ( blessed($result) && $result->isa('Langertha::Response') ) {
    $result = $result->clone_with(
      timing => _merge_timing_field( $result->timing, total_seconds => $elapsed ),
    );
  }

  if ( $synth_tool_name && blessed($result) && $result->isa('Langertha::Response') ) {
    my $args = $self->decode_loose_json( $result->content );
    # A tool's arguments are a JSON object. Only synthesize the ToolCall when the
    # model actually returned one — a non-object result (e.g. a bare JSON array)
    # would otherwise be coerced to empty {} in Response BUILDARGS and the
    # synthetic call would falsely claim success with no arguments. Leaving
    # tool_calls unset lets the caller see the gap (the raw content is still on
    # Response.content) instead of a hollow success.
    if ( ref $args eq 'HASH' ) {
      $result = $result->clone_with(
        tool_calls => [{
          name      => $synth_tool_name,
          arguments => $args,
          synthetic => 1,
        }],
      );
    }
    else {
      $log->debugf(
        "[%s] forced-tool fallback: '%s' response was not a JSON object; no synthetic tool_call attached",
        ref $self, $synth_tool_name);
    }
  }

  if ( $self->can('has_rate_limit') && $self->has_rate_limit
       && ref $result && $result->isa('Langertha::Response') ) {
    $result = $result->clone_with( rate_limit => $self->rate_limit );
  }
  return $result;
}

=method simple_chat_f

    # Traditional Future style
    my $response = $engine->simple_chat_f(@messages)->get;

    # With async/await (recommended)
    use Future::AsyncAwait;
    async sub my_chat {
        my $response = await $engine->simple_chat_f(@messages);
        return $response;
    }

Async version of L</simple_chat>. Returns a L<Future> that resolves to the
response text. The HTTP backend comes from L<Langertha::Role::AsyncHTTP>:
L<Net::Async::HTTP> when installed (loaded lazily on first call), otherwise a
synchronous L<LWP::UserAgent> fallback under which the call blocks and several
C<_f> calls run one after another rather than concurrently.

For requests that need named arguments (tools, tool_choice,
response_format, etc.) use L</chat_f>; C<simple_chat_f> delegates to it.

=cut

=method chat_f

    my $response = await $engine->chat_f(
      messages       => [ ... ],
      tools          => [ $tool, ... ],
      tool_choice    => { type => 'tool', name => 'extract' },
      response_format => { ... },
      temperature    => 0.7,
      max_tokens     => 512,
      # any other engine-specific extras pass straight through
    );

Async I<single-turn> chat with named arguments. Returns a L<Future>
resolving to a L<Langertha::Response>. The caller is responsible for
acting on any C<tool_calls> the engine emits — C<chat_f> does not
loop. For the multi-turn MCP tool-calling loop use
L<Langertha::Role::Tools/chat_with_tools_f> instead.

C<tools> in C<chat_f> can be a mix of provider-shape HashRefs
(OpenAI, Anthropic, MCP, Gemini); the engine's C<chat_request> handles
the per-provider serialization. The L<Langertha::Tool> value object is
the canonical normalizer (C<from_hash> accepts every shape, the
C<to_PROVIDER> methods produce the wire payload).

The canonical per-request controls (karr #46) are normalized like
C<messages>/C<tools> instead of being spread as raw target-wire kwargs:
C<temperature>, C<max_tokens>, C<response_format>, C<seed>,
C<parallel_tool_use>, C<reasoning_effort>, C<thinking_budget>,
C<prompt_cache>, C<prompt_cache_ttl> and C<prompt_cache_key>. Each engine's
C<chat_request> places them on its own wire (Ollama C<options>, Gemini
C<generationConfig>, Anthropic C<output_config>+C<thinking>, ...) via the same
value objects the engine attributes use, so the same call is correct across
engine families. A per-request control beats the configured engine attribute
on a per-key basis. Any other key still passes straight through to the wire as
before.

When the caller asks for a forced named tool on an engine that cannot
do native named-tool-forcing but supports C<json_schema>
response_format (currently L<Langertha::Engine::Perplexity>), the
request is automatically rewritten to use the JSON Schema path and the
response is loose-parsed; the resulting L<Langertha::Response> exposes
the parsed arguments via L<Langertha::Response/tool_call_args> with
C<synthetic =E<gt> 1> on the synthesized tool_call entry.

=cut

sub simple_chat_stream_f {
  my ($self, @messages) = @_;
  return $self->simple_chat_stream_realtime_f(undef, @messages);
}

=method simple_chat_stream_f

    my ($content, $chunks) = $engine->simple_chat_stream_f(@messages)->get;

Async streaming without a real-time callback. Convenience wrapper around
L</simple_chat_stream_realtime_f> with C<undef> as the callback. Returns a
L<Future> that resolves to C<($content, \@chunks, \%timing, $thinking)> — the
same tuple as L</chat_stream_realtime_f>; the trailing elements are additive.

=cut

async sub simple_chat_stream_realtime_f {
  my ($self, $chunk_callback, @messages) = @_;

  return await $self->chat_stream_realtime_f(
    messages       => \@messages,
    chunk_callback => $chunk_callback,
  );
}

async sub chat_stream_realtime_f {
  my ( $self, %opts ) = @_;

  my $chunk_callback = delete $opts{chunk_callback};
  my $messages = delete $opts{messages} // [];
  my @messages = ref $messages eq 'ARRAY' ? @$messages : ($messages);

  croak "".(ref $self)." does not support streaming"
    unless $self->can('chat_stream_request');

  # Provider mutual-exclusion guard (karr #148) — streaming path. Same per-model
  # seam as chat_f; the streaming flag lets a rule refuse a combination that is
  # rejected only when streaming (e.g. Groq structured outputs, which do not
  # support streaming at all).
  $self->_check_capability_exclusions(
    has_tools       => $self->_chat_tools_requested(\%opts),
    response_format => $opts{response_format},
    streaming       => 1,
  );

  # Same canonical-control extraction as chat_f (karr #46).
  my $controls = $self->_extract_controls(\%opts);

  my $request = $self->chat_stream_request( $self->chat_messages(@messages),
    ( %$controls ? ( controls => $controls ) : () ),
    %opts );
  my @all_chunks;
  my $buffer = '';
  my $format = $self->stream_format;
  my $response_status;
  my $t0           = [gettimeofday];
  my $ttft_seconds;

  # A die in the chunk-sub (a malformed stream line, or the caller's
  # chunk_callback) must fail this request's future on every backend. An
  # event-loop backend (Net::Async::HTTP) runs the chunk-sub inside the loop's
  # read handler, where a die would unwind out of the loop into whatever is
  # driving it and leave this request pending (karr k194, ADR 0027).
  my ( $request_f, $stream_error );
  my $abort_f = Future->new;
  $request_f = $self->_async_http->do_request(
    request => $request,
    on_header => sub {
      my ($response) = @_;
      $response_status = $response;

      # Return a callback that handles each body chunk
      return sub {
        my ($data) = @_;
        return if defined $stream_error;  # already failed; drop the rest
        return unless defined $data;      # undef signals end of body

        my $ok = eval {
          $buffer .= $data;
          my $chunks = $self->_process_stream_buffer(\$buffer, $format);
          for my $chunk (@$chunks) {
            $ttft_seconds = tv_interval($t0) unless defined $ttft_seconds;
            push @all_chunks, $chunk;
            $chunk_callback->($chunk) if $chunk_callback;
          }
          1;
        };
        return if $ok;
        $stream_error = $@ || "streaming callback died\n";
        # A synchronous backend (Langertha::Request::SyncHTTP) runs the
        # chunk-sub before do_request returns: die again so it stops reading
        # and fails its own future with the original exception. Once the
        # backend has handed back its future, fail ours instead; wait_any then
        # cancels the transfer.
        die $stream_error unless $request_f;
        $abort_f->fail( $stream_error, http => $response, $request );
      };
    },
  );
  await Future->wait_any( $request_f, $abort_f );

  unless ($response_status->is_success) {
    die "".(ref $self)." streaming request failed: ".$response_status->status_line;
  }

  # Process remaining buffer
  if ($buffer ne '') {
    my $chunks = $self->_process_stream_buffer(\$buffer, $format, 1);
    for my $chunk (@$chunks) {
      $ttft_seconds = tv_interval($t0) unless defined $ttft_seconds;
      push @all_chunks, $chunk;
      $chunk_callback->($chunk) if $chunk_callback;
    }
  }

  my $content      = join('', map { $_->content } @all_chunks);
  my $thinking     = $self->aggregate_thinking(\@all_chunks);
  my $total_seconds = tv_interval($t0);
  return ($content, \@all_chunks, {
    ttft_seconds  => $ttft_seconds,
    total_seconds => $total_seconds,
  }, $thinking);
}

sub aggregate_tool_calls {
  my ( $self, $chunks ) = @_;
  return [] unless ref($chunks) eq 'ARRAY';
  my @tcs;
  for my $c (@$chunks) {
    next unless eval { $c->has_tool_calls };
    push @tcs, @{ $c->tool_calls };
  }
  return \@tcs;
}

=method aggregate_tool_calls

    my $tool_calls = $engine->aggregate_tool_calls( $chunks );

Walks an ArrayRef of L<Langertha::Stream::Chunk> objects and returns
the flat list of L<Langertha::ToolCall> objects collected from any
chunks that carry C<tool_calls>. Returns an empty ArrayRef if none of
the chunks emitted tool calls.

This is the collection seam for streamed tool-call aggregation, the
streaming counterpart to L<Langertha::Response/tool_calls>. Assembling
fragmented tool-call deltas (OpenAI's C<delta.tool_calls> stream,
Anthropic's C<input_json_delta>) into a finished L<Langertha::ToolCall>
on the chunk belongs in C<parse_stream_chunk> — but B<no engine dialect
does that assembly today>, so C<Stream::Chunk> carries no tool calls on
the streaming path and this helper returns an empty list in practice. It
is the collection point for when an engine implements that assembly, a
known and accepted gap; use the non-streaming path when you need tool
calls.

=cut

sub aggregate_thinking {
  my ( $self, $chunks ) = @_;
  return undef unless ref($chunks) eq 'ARRAY';
  my $thinking = '';
  my $seen = 0;
  for my $c (@$chunks) {
    my $t = eval { $c->has_thinking ? $c->thinking : undef };
    next unless defined $t;
    $thinking .= $t;
    $seen = 1;
  }
  return $seen ? $thinking : undef;
}

=method aggregate_thinking

    my $thinking = $engine->aggregate_thinking( $chunks );

Walks an ArrayRef of L<Langertha::Stream::Chunk> objects and concatenates the
C<thinking> text of every chunk that carries one, in stream order — the way
L</chat_stream_realtime_f> concatenates C<content>. Returns C<undef> when no
chunk carried thinking, so the streamed result mirrors
L<Langertha::Response/thinking> (also C<undef> when the engine surfaced none).

This is the streaming counterpart to the native C<thinking> that
L<Langertha::Response> exposes on the non-streaming path. Each dialect stream
parser fills C<Stream::Chunk-E<gt>thinking> from its own delta spelling (see
L<Langertha::Stream::Chunk/thinking>); this helper just reassembles the
fragments.

=cut

=method simple_chat_stream_realtime_f

    # With async/await (recommended)
    use Future::AsyncAwait;
    async sub my_stream {
        my ($content, $chunks) = await $engine->simple_chat_stream_realtime_f(
            sub { print shift->content },
            @messages
        );
        return $content;
    }

    # Traditional Future style
    my $future = $engine->simple_chat_stream_realtime_f($callback, @messages);
    my ($content, $chunks) = $future->get;

Async streaming with real-time callback. C<$callback> is called with each
L<Langertha::Stream::Chunk> as it arrives from the server (each chunk may carry
incremental C<thinking>). Returns a L<Future> that resolves to
C<($content, \@chunks, \%timing, $thinking)>, the same tuple as
L</chat_stream_realtime_f>; the trailing elements are additive, so callers
destructuring only C<($content, \@chunks)> keep working.

This is the recommended method for real-time streaming in async applications.
Pass C<undef> as the callback (or use L</simple_chat_stream_f>) if you only
need the final result.

This is a thin wrapper around L</chat_stream_realtime_f>; existing callers
keep working unchanged. For requests that need named arguments (tools,
tool_choice, response_format, temperature, max_tokens, etc.) use
L</chat_stream_realtime_f> directly.

=cut

=method chat_stream_realtime_f

    my ($content, $chunks) = await $engine->chat_stream_realtime_f(
        messages       => [ ... ],
        chunk_callback => sub { print shift->content },
        temperature    => 0.7,
        max_tokens     => 512,
        # any other engine-specific extras pass straight through
    );

Async I<single-turn> streaming chat with named arguments. C<messages> is
required (ArrayRef or a single message); C<chunk_callback> is called with each
L<Langertha::Stream::Chunk> as it arrives from the server. The canonical
per-request controls (karr #46) — C<temperature>, C<max_tokens>,
C<response_format>, C<seed>, C<parallel_tool_use>, C<reasoning_effort>,
C<thinking_budget>, C<prompt_cache>, C<prompt_cache_ttl>, C<prompt_cache_key> —
are extracted and handed to L</chat_stream_request> under C<controls>, exactly
as in L</chat_f>. All other options (tools, tool_choice, and any engine-specific
extras) pass straight through.

Returns a L<Future> that resolves to C<($content, \@chunks, \%timing,
$thinking)> where C<$content> is the full concatenated text, C<\@chunks> the
collected L<Langertha::Stream::Chunk> objects, C<\%timing> carries
C<ttft_seconds> and C<total_seconds>, and C<$thinking> is the aggregated
chain-of-thought (C<undef> when the engine surfaced none), assembled from the
per-chunk C<thinking> deltas by L</aggregate_thinking> so it matches the native
L<Langertha::Response/thinking> of the non-streaming L</chat_f> on the same
engine and prompt. The trailing element is additive: callers destructuring only
the first three keep working.

If C<chunk_callback> dies, or a stream line cannot be parsed, the returned
future B<fails> with that exception, the rest of the stream is dropped and the
transfer is stopped. This holds on every HTTP backend: on L<Net::Async::HTTP>
the exception does not escape the event loop, so other requests on the same
loop are unaffected (L<Langertha::Role::AsyncHTTP>).

This is the streaming counterpart to L</chat_f>. Unlike L</chat_f> it does
not apply the forced-tool fallback (rewriting a named C<tool_choice> into a
C<response_format> on engines without C<tool_choice_named>); synthesizing a
C<tool_calls> entry from the accumulated stream text is a separate follow-up
concern.

C<response_format> is honored on the streaming path only where the engine
has a native wire form (Gemini C<responseJsonSchema>, Ollama C<format>,
OpenAI-compatible C<response_format>). Anthropic-family engines have no
native form and their synthesized-tool rewrite has no streaming lift, so
they consume the key and croak — use L</chat_f> for structured output there.

=cut

sub _process_stream_buffer {
  my ($self, $buffer_ref, $format, $final) = @_;

  my @chunks;

  if ($format eq 'sse') {
    # On the final flush ($final, passed after the stream body ends) the last
    # event can arrive without its terminating blank line — the connection just
    # closed. Append one so the loop below consumes the remainder instead of
    # dropping it (its finish_reason / usage would be lost, and the sync
    # process_stream_data path — which splits the whole body at once — keeps it).
    # Event separators and line breaks are matched CRLF-tolerantly (\r?\n) to
    # match that sync path (split /\r?\n/).
    $$buffer_ref .= "\n\n" if $final && $$buffer_ref ne '';
    while ($$buffer_ref =~ s/^(.*?)\r?\n\r?\n//s) {
      my $block = $1;
      for my $line (split /\r?\n/, $block) {
        next if $line eq '' || $line =~ /^:/;
        if ($line =~ /^data:\s*(.*)$/) {
          my $json_data = $1;
          next if $json_data eq '[DONE]' || $json_data eq '';
          my $parsed = $self->json->decode($json_data);
          my $chunk = $self->parse_stream_chunk($parsed);
          push @chunks, $chunk if $chunk;
        }
      }
    }
  } elsif ($format eq 'ndjson') {
    $$buffer_ref .= "\n" if $final && $$buffer_ref ne '';
    while ($$buffer_ref =~ s/^(.*?)\r?\n//s) {
      my $line = $1;
      next if $line eq '';
      my $parsed = $self->json->decode($line);
      my $chunk = $self->parse_stream_chunk($parsed);
      push @chunks, $chunk if $chunk;
    }
  }

  return \@chunks;
}

with 'Langertha::Role::ThinkTag', 'Langertha::Role::Langfuse', 'Langertha::Role::AsyncHTTP';

=seealso

=over

=item * L<Langertha::Role::Langfuse> - Observability integration (composed by this role)

=item * L<Langertha::Role::SystemPrompt> - System prompt injection

=item * L<Langertha::Role::Streaming> - Stream parsing (SSE / NDJSON)

=item * L<Langertha::Role::Tools> - Tool calling on top of chat

=item * L<Langertha::Role::Models> - Model selection

=item * L<Langertha::Stream> - Stream iterator

=item * L<Langertha::Stream::Chunk> - Individual stream chunk

=back

=cut

1;
