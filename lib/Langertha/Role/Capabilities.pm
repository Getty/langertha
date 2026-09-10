package Langertha::Role::Capabilities;
# ABSTRACT: Engine-capability registry derived from composed roles
our $VERSION = '0.503';
use Moose::Role;

=head1 SYNOPSIS

    if ( $engine->supports('tool_choice_named') ) { ... }

    my $caps = $engine->engine_capabilities;
    for my $cap ( sort keys %$caps ) {
        say "$cap" if $caps->{$cap};
    }

    # Engine-level override for a wire reality the role inventory
    # cannot express (e.g. provider only accepts string tool_choice):
    around engine_capabilities => sub {
      my ( $orig, $self, @rest ) = @_;
      my $caps = $self->$orig(@rest);
      delete $caps->{tool_choice_named};
      return $caps;
    };

=head1 DESCRIPTION

Composed by L<Langertha::Role::Chat> (and therefore present on every
engine), this role provides the C<engine_capabilities> method plus the
C<supports> helper. The default implementation derives the flag set
from which capability-bearing roles the engine composes — no per-role
plumbing required, the registry below is the single source of truth.

Engines override (via C<around>) when the wire reality differs from
the role inventory — for example to clear C<tool_choice_named> on a
provider that only accepts string forms of C<tool_choice>.

The mapping from role to flag is intentionally kept inside this one
module so adding a new capability is a single-file change. The role
itself does not need to know about C<engine_capabilities>.

=cut

# Role-name => list of capability flag names that role contributes.
# Plus implicit:
#   chat            -> simple_chat works (Role::Chat is composed)
#   streaming       -> chat_stream_request is wired up (Role::Streaming)
#   tools_native    -> Role::Tools (the named flags below come too)
#   tools_hermes    -> Role::HermesTools
#   ... see %ROLE_TO_CAPS below.
# Every Langertha::Role::* is on one of two axes (ADR 0016 decision 2):
# a capability (an entry here) or envelope/infrastructure (the allowlist
# in t/78_capability_registry.t). That guard fails on a role in neither,
# so a new role cannot quietly skip the decision.
my %ROLE_TO_CAPS = (
  'Langertha::Role::Chat'             => [qw( chat )],
  'Langertha::Role::Streaming'        => [qw( streaming )],
  'Langertha::Role::Tools'            => [qw(
    tools_native tool_choice_auto tool_choice_any tool_choice_none tool_choice_named
  )],
  'Langertha::Role::HermesTools'      => [qw( tools_hermes )],
  'Langertha::Role::ResponseFormat'   => [qw(
    response_format_json_object response_format_json_schema
  )],
  'Langertha::Role::Embedding'        => [qw( embedding )],
  'Langertha::Role::Transcription'    => [qw( transcription )],
  'Langertha::Role::ImageGeneration'  => [qw( image_generation )],
  'Langertha::Role::Temperature'      => [qw( temperature )],
  'Langertha::Role::ReasoningEffort'  => [qw( reasoning_effort )],
  'Langertha::Role::PromptCache'      => [qw( prompt_cache prompt_cache_key )],
  'Langertha::Role::CachedContent'    => [qw( cached_content )],
  'Langertha::Role::Seed'             => [qw( seed )],
  'Langertha::Role::ContextSize'      => [qw( context_size )],
  'Langertha::Role::ResponseSize'     => [qw( response_size )],
  'Langertha::Role::SystemPrompt'     => [qw( system_prompt )],
  'Langertha::Role::KeepAlive'        => [qw( keep_alive )],
  'Langertha::Role::ParallelToolUse'  => [qw( parallel_tool_use )],
  'Langertha::Role::Runtime::MetricsPoll' => [qw( runtime_metrics )],
  'Langertha::Role::RuntimeKnobs'    => [qw( prefix_caching )],
);

sub engine_capabilities {
  my ($self) = @_;
  my %caps;
  for my $role ( keys %ROLE_TO_CAPS ) {
    next unless $self->does($role);
    $caps{$_} = 1 for @{ $ROLE_TO_CAPS{$role} };
  }
  # Layer 3 (ADR 0002 amendment, pending ADR 0019): per-model refinement.
  # The tool / structured-output wire reality is often per-MODEL, not
  # per-engine (kimi-k3 forbids a forced named tool while its K2.x siblings
  # allow it; deepseek-reasoner clamps differ from deepseek-chat). Engines
  # declare a model-id/pattern -> {cap => 0|1} table in
  # model_capability_corrections; it refines the role-derived base for the
  # currently selected chat_model. Engine-WIDE corrections stay in
  # `around engine_capabilities` (the outer endpoint-reality gate, layer 2).
  $self->_apply_model_capability_corrections(\%caps);
  return \%caps;
}

# Default: no per-model corrections. Engines override with a declarative,
# ordered list of ( $matcher => \%overrides ) pairs — see the =method below.
sub model_capability_corrections { return () }

sub _apply_model_capability_corrections {
  my ( $self, $caps ) = @_;
  my @corrections = $self->model_capability_corrections;
  return unless @corrections;
  # chat_model is the model that actually carries tools / tool_choice /
  # response_format on the wire (Role::Chat); guard for the rare consumer
  # of engine_capabilities that has no model surface at all.
  my $model = $self->can('chat_model') ? $self->chat_model : undef;
  return unless defined $model && length $model;
  while ( @corrections >= 2 ) {
    my ( $matcher, $overrides ) = splice @corrections, 0, 2;
    my $hit = ref $matcher eq 'Regexp' ? ( $model =~ $matcher )
            :                            ( $model eq $matcher );
    next unless $hit;
    # Later matching entries win on a shared flag. A true value asserts the
    # capability, a false value clears it.
    for my $cap ( keys %$overrides ) {
      if ( $overrides->{$cap} ) { $caps->{$cap} = 1 }
      else                      { delete $caps->{$cap} }
    }
  }
  return;
}

=method engine_capabilities

    my $caps = $engine->engine_capabilities;

Returns a HashRef of capability flags. The default derives the flag set in
three layers: (1) it scans the composed role inventory and sets flags from
the static role-to-flags map (ADR 0002); (2) an engine may correct the
whole-endpoint wire reality via C<around> (remove flags the wire cannot
deliver at all, or add an ad-hoc flag — the outer gate); (3) it applies the
engine's C<model_capability_corrections> for the currently selected
C<chat_model>, refining the base where the wire reality is per-model rather
than per-engine (ADR 0002 amendment, pending ADR 0019).

A capability flag means B<the wire accepts the field>, not that any given
model will honor it. For example C<reasoning_effort> being true says the
engine's API will accept a reasoning-effort field on the request; whether a
particular model supports reasoning is a separate runtime concern (every
reasoning field 400s on a non-reasoning model). Engines whose wire never
accepts the field clear the flag via C<around engine_capabilities>
(e.g. MiniMax on its OpenAI endpoint, Perplexity).

Prompt caching is request-side-asymmetric, so it gets B<two> flags rather
than one: C<prompt_cache> means the wire accepts an explicit cache-enable
breakpoint (Anthropic's C<cache_control>), while C<prompt_cache_key> means the
wire accepts an OpenAI-style routing hint (caching itself is automatic there).
The single C<Langertha::Role::PromptCache> role contributes both; the
C<OpenAIBase> / C<AnthropicBase> base classes each clear the one that does not
apply to their wire, so the OpenAI family advertises only the key and the
Anthropic family only the enable breakpoint.

C<prefix_caching> (from C<Langertha::Role::RuntimeKnobs>, composed on the
self-hosted vLLM / SGLang / llama.cpp engines) means B<the wire accepts
prefix-cache isolation/reuse controls> (C<cache_salt>, C<cache_prompt>,
C<n_cache_reuse>, C<id_slot>, C<priority>, C<return_cached_tokens_details>,
C<extra_key>) — B<not> that prefix caching is on. Whether the server actually
caches is launch state the client cannot observe (vLLM C<--enable-prefix-caching>,
SGLang C<--enable-mixed-prefill> / C<--enable-prefix-caching>, llama.cpp
C<--cache_prompt>); the flag only says the request body may carry the knobs.

=cut

=method model_capability_corrections

    sub model_capability_corrections {
      return (
        'kimi-k3'       => { tool_choice_named => 0 },  # exact model id
        qr/\Akimi-k2\./ => { tool_choice_any   => 0 },  # a model family
      );
    }

The per-model correction layer (layer 3 of C<engine_capabilities>).
Returns an B<ordered> list of C<< ( $matcher => \%overrides ) >> pairs.
C<$matcher> is either an exact model-id string (matched with C<eq>) or a
C<qr//> regex (matched against the engine's C<chat_model>) — model ids come
in families (C<gpt-5.6-*>, C<kimi-k2.7-*>), so both forms are supported.
C<\%overrides> maps a capability flag to C<1> (assert) or C<0> (clear);
later matching entries win on a shared flag.

This is the sanctioned home for a wire reality that differs B<per model>
rather than per engine — for example a model that forbids a forced named
tool while its siblings allow it. Engine-B<wide> corrections (the whole
endpoint never accepts a field) belong in C<around engine_capabilities>
instead. The default returns an empty list, so engines that need no
per-model refinement pay nothing.

=cut

sub supports {
  my ( $self, $cap ) = @_;
  return !!$self->engine_capabilities->{$cap};
}

=method supports

    if ( $engine->supports('tool_choice_named') ) { ... }

Convenience wrapper that returns a true value when the named capability
is present and truthy in C<engine_capabilities>.

=cut

1;
