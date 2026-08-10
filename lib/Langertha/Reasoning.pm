package Langertha::Reasoning;
# ABSTRACT: Immutable normalized reasoning-effort control with cross-provider conversion
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

=head1 SYNOPSIS

    my $r = Langertha::Reasoning->new(
        effort => 'high',
        model  => 'claude-opus-4-8',
    );
    my %kwargs = $r->to('anthropic');
    # ( output_config => { effort => 'high' }, thinking => { type => 'adaptive' } )

    # Gemini 2.5 takes an integer thinking_budget instead of a level
    my $rb = Langertha::Reasoning->new(
        thinking_budget => 2048,
        model           => 'gemini-2.5-pro',
    );
    my %kw = $rb->to('gemini');
    # ( thinkingConfig => { thinkingBudget => 2048 } )

=head1 DESCRIPTION

Canonical value object for the request-side reasoning-effort knob, dispatched
by an engine's C<reasoning_wire_format>. Mirrors L<Langertha::Tool> /
L<Langertha::ToolChoice>: the value-set clamping and per-provider placement of
the field live in this one reviewable place rather than scattered across
engines (ADR 0001).

The normalized vocabulary is the OpenAI superset
C<none|minimal|low|medium|high|xhigh|max>. Each C<to_*> serializer clamps that
vocabulary to what the target wire actually accepts and returns the body kwargs
to merge into the request.

Gemini splits its reasoning knob by model generation: Gemini 3 accepts a
collapsed C<thinkingLevel> (C<low>|C<high>) emitted from C<effort>; Gemini 2.5
takes a C<thinkingBudget> integer instead. Exactly one of the two fields is
emitted per request — never both. C<BUILD> rejects every
C<effort>/C<thinking_budget> combination that would produce an ambiguous wire
form (either field on the wrong generation, or both fields together on any
generation). The rule is "exactly one native control per generation",
enforced loudly before any request is built.

=cut

# Optional attributes with normal Moose predicates. No `default` / `Maybe[...]`
# so that `has_effort` / `has_thinking_budget` reflect whether the caller
# supplied the field — the standard Moose predicate (true when set, false when
# not set) is what BUILD and the serializers dispatch on.
has effort => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_effort',
);

=attr effort

The normalized reasoning effort, one of C<none|minimal|low|medium|high|xhigh|max>.
Optional (must not coexist with C<thinking_budget> on any Gemini generation;
see L</BUILD>). On Gemini 3, C<effort> is the only knob and emits
C<thinkingConfig.thinkingLevel>. Setting C<effort> on a Gemini 2.5 model is
rejected — Gemini 2.5 takes the integer budget, not the level vocabulary.

=cut

has model => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_model',
);

=attr model

Optional model name. Used by L</to_anthropic> to detect always-on
"Fable-class" models (where C<thinking:{type:disabled}> 400s and the
C<thinking> field must be omitted) and by L</to_gemini> to dispatch between
Gemini 2.5 (C<thinkingBudget>) and Gemini 3 (C<thinkingLevel>).

=cut

has thinking_budget => (
  is        => 'ro',
  isa       => 'Int',
  predicate => 'has_thinking_budget',
);

=attr thinking_budget

Optional integer thinking budget for Gemini 2.5 models. When set on a Gemini
2.5 model (model id starting with C<gemini-2.5>), L</to_gemini> emits
C<thinkingConfig.thinkingBudget> as the integer. Setting C<thinking_budget>
on a Gemini 3 model, or setting it together with C<effort> on any model, is
rejected at construction time (L</BUILD>) — the two fields speak different
units (binary level vs integer tokens) and a combined or wrong-generation wire
form would be ambiguous.

=cut

# OpenAI /chat/completions reasoning_effort accepts this subset of the
# normalized vocabulary; max is not accepted there and is dropped.
my %OPENAI_EFFORT = map { $_ => 1 } qw( none minimal low medium high xhigh );

# Anthropic output_config.effort accepts low|medium|high|xhigh|max; the
# normalized none/minimal have no Anthropic equivalent and are dropped.
my %ANTHROPIC_EFFORT = map { $_ => 1 } qw( low medium high xhigh max );

# Build-time wire-truth gate: exactly one native control per generation, never
# both. Errors here surface before the request is built (Langertha::Engine::Gemini
# calls to() inside chat_request), so a misconfigured engine never produces an
# ambiguous wire form.
sub BUILD {
  my ( $self ) = @_;

  my $has_effort = $self->has_effort;
  my $has_budget = $self->has_thinking_budget;
  my $model      = $self->has_model ? $self->model : '';

  if ( $has_effort && $has_budget ) {
    croak "Langertha::Reasoning: 'effort' and 'thinking_budget' are mutually "
      . "exclusive — pick one (effort -> thinkingLevel, thinking_budget -> "
      . "thinkingBudget); model='" . $model . "'";
  }

  if ( $has_budget && !_is_gemini_25($model) ) {
    croak "Langertha::Reasoning: 'thinking_budget' is only valid on Gemini 2.5 "
      . "models (model id starting with 'gemini-2.5'); got model='" . $model . "'";
  }

  if ( $has_effort && _is_gemini_25($model) ) {
    croak "Langertha::Reasoning: 'effort' is not valid on Gemini 2.5 models — "
      . "use 'thinking_budget' (integer tokens) instead; got model='"
      . $model . "'";
  }
}

sub _is_fable_class {
  my ( $self ) = @_;
  return ( $self->has_model && $self->model =~ /fable|mythos/i ) ? 1 : 0;
}

# Gemini 2.5 generationConfig.thinkingConfig.thinkingBudget is an integer
# tokens budget (no level vocabulary); Gemini 3 takes thinkingLevel instead.
# Match the model-id family the way the gemini API does.
sub _is_gemini_25 { $_[0] =~ /\Agemini-2\.5/ ? 1 : 0 }

# Gemini 3 generationConfig.thinkingConfig.thinkingLevel is low|high
# (gemini-3-pro is low|high only; flash/3.1-pro add medium). Collapse the
# normalized vocabulary to the universally-accepted binary, splitting at high.
sub to_low_high {
  my ( $self ) = @_;
  my $e = $self->effort;
  return ( $e eq 'high' || $e eq 'xhigh' || $e eq 'max' ) ? 'high' : 'low';
}

=method to_low_high

Collapses the normalized effort to Gemini's binary C<low>/C<high>.

=cut

sub to_openai {
  my ( $self ) = @_;
  return () unless $self->has_effort;
  my $e = $self->effort;
  return () unless $OPENAI_EFFORT{$e};
  return ( reasoning_effort => $e );
}

sub to_responses {
  my ( $self ) = @_;
  return () unless $self->has_effort;
  return ( reasoning => { effort => $self->effort } );
}

sub to_anthropic {
  my ( $self ) = @_;
  return () unless $self->has_effort;
  my $e = $self->effort;
  return () unless $ANTHROPIC_EFFORT{$e};
  return (
    output_config => { effort => $e },
    # Adaptive-thinking models need thinking:{type:adaptive} or thinking stays
    # off; always-on "Fable-class" models 400 on thinking:{type:disabled} and
    # need no thinking field at all (thinking is always on).
    ( $self->_is_fable_class ? () : ( thinking => { type => 'adaptive' } ) ),
  );
}

sub to_gemini {
  my ( $self ) = @_;
  if ( $self->has_thinking_budget ) {
    # BUILD has already verified the model is Gemini 2.5.
    return ( thinkingConfig => { thinkingBudget => $self->thinking_budget } );
  }
  return () unless $self->has_effort;
  return ( thinkingConfig => { thinkingLevel => $self->to_low_high } );
}

# Maps a reasoning_wire_format tag to the per-format serializer method.
my %TO_METHOD = (
  openai    => 'to_openai',
  responses => 'to_responses',
  anthropic => 'to_anthropic',
  gemini    => 'to_gemini',
);

sub to {
  my ( $self, $fmt ) = @_;
  my $method = $TO_METHOD{ $fmt // '' }
    or croak "Langertha::Reasoning: unknown reasoning wire format '" . ( $fmt // '' ) . "'";
  return $self->$method;
}

=method to

    my %kwargs = $r->to($reasoning_wire_format);

Dispatch to the per-format serializer. Returns the body kwargs to merge into
the request (an empty list when the value is unsupported on that wire).

=cut

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Role::ReasoningEffort> - The composed role exposing C<reasoning_effort>
and C<thinking_budget>

=item * L<Langertha::ToolChoice> - Sibling value object for tool-selection policy

=back

=cut

1;
