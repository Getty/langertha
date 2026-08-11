package Langertha::Role::ReasoningEffort;
# ABSTRACT: Role for an engine with a request-side reasoning-effort control
our $VERSION = '0.503';
use Moose::Role;
use Langertha::Reasoning;

has reasoning_effort => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_reasoning_effort',
);

=attr reasoning_effort

Normalized request-side reasoning effort. Vocabulary (the OpenAI superset):
C<none>, C<minimal>, C<low>, C<medium>, C<high>, C<xhigh>, C<max>. When set, it
is translated to the provider-specific wire field via L<Langertha::Reasoning>
keyed by L</reasoning_wire_format>; values the target wire cannot accept are
dropped. When not set, no reasoning field is emitted and the model's own
default applies.

Note this is a request-side control, distinct from L<Langertha::Role::ThinkTag>
(which filters C<E<lt>thinkE<gt>> tags out of responses).

=cut

has thinking_budget => (
  is        => 'ro',
  isa       => 'Int',
  predicate => 'has_thinking_budget',
);

=attr thinking_budget

Optional integer thinking budget, currently consumed only by Gemini 2.5 models
(L<Langertha::Engine::Gemini>): on C<gemini-2.5-*> the value is emitted as
C<generationConfig.thinkingConfig.thinkingBudget>. On Gemini 3 models
C<thinking_budget> is rejected — Gemini 3 takes C<thinkingLevel>, not the
integer budget; setting both L</reasoning_effort> and C<thinking_budget> on a
Gemini 3 model croaks at construction (L<Langertha::Reasoning/BUILD>). When
unset, no budget field is emitted. (Anthropic legacy C<budget_tokens> is
deliberately not modeled: it 400s on current Claude families.)

=cut

has reasoning_wire_format => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  builder => '_build_reasoning_wire_format',
);

# Defaults to the OpenAI /chat/completions dialect; AnthropicBase, Gemini and
# OpenAIResponses override the builder. Deliberately NOT keyed off
# tool_wire_format — engines sharing tool_wire_format=openai (DeepSeek, MiniMax,
# Groq) disagree on the reasoning field.
sub _build_reasoning_wire_format { 'openai' }

=attr reasoning_wire_format

    reasoning_wire_format => 'anthropic'

The per-engine enum naming which reasoning dialect this engine speaks —
C<openai> | C<anthropic> | C<gemini> | C<responses>. Drives the value-object
dispatch in L</reasoning_kwargs>. The default follows the engine base-class
hierarchy: C<OpenAIBase> leaves it at C<openai>, C<AnthropicBase> overrides to
C<anthropic>, C<Gemini> to C<gemini>, C<OpenAIResponses> to C<responses>.

=cut

sub reasoning_kwargs {
  my ( $self ) = @_;
  return () unless $self->has_reasoning_effort || $self->has_thinking_budget;
  return Langertha::Reasoning->new(
    defined $self->reasoning_effort
      ? ( effort => $self->reasoning_effort )
      : (),
    $self->has_thinking_budget
      ? ( thinking_budget => $self->thinking_budget )
      : (),
    ( $self->can('chat_model') ? ( model => $self->chat_model ) : () ),
  )->to( $self->reasoning_wire_format );
}

=method reasoning_kwargs

    my %kwargs = $engine->reasoning_kwargs;

Returns the body kwargs to merge into a chat request for the configured
C<reasoning_effort> and/or L</thinking_budget>, serialized for
L</reasoning_wire_format> via L<Langertha::Reasoning>. Empty list when neither
is set, or when the value is unsupported on the engine's wire. Engines
override this to model wire divergence within a shared format (e.g. DeepSeek's
model-gated split, or MiniMax/Perplexity returning an empty list).

=cut

=seealso

=over

=item * L<Langertha::Reasoning> - The value object this role dispatches to

=item * L<Langertha::Role::Capabilities> - Where C<reasoning_effort> is registered

=item * L<Langertha::Role::Temperature> - Sibling request-side sampling control

=back

=cut

1;
