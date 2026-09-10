package Langertha::Reasoning;
# ABSTRACT: Immutable normalized reasoning-effort control with cross-provider conversion
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );
use JSON::MaybeXS;

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

The OpenAI clamp is B<model-gated>, not wire-gated: Chat Completions
(C<to_openai>) and the Responses API (C<to_responses>) C<$ref> the identical
C<ReasoningEffort> schema, so both share one per-model gate and can never
diverge for the same model. The accepted set differs per model generation —
the gpt-5.6/gpt-5.5 generation accepts C<none>/C<xhigh>/(C<max>) but not
C<minimal>; the legacy gpt-5 generation accepts C<minimal> but not
C<none>/C<xhigh>/C<max> — so no single wire-level clamp is correct. Unlisted
model ids keep the full vocabulary. See L</to_openai>.

Gemini splits its reasoning knob by model generation: Gemini 3 accepts a
C<thinkingLevel> emitted from C<effort> (vocabulary
C<minimal>|C<low>|C<medium>|C<high>, clamped to the subset the configured
model family accepts — see L</to_gemini_level>); Gemini 2.5 takes a
C<thinkingBudget> integer instead. Exactly one of the two fields is
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
C<thinkingConfig.thinkingLevel>, model-gated clamped to the level subset the
configured model family accepts (L</to_gemini_level>). Setting C<effort> on a
Gemini 2.5 model is rejected — Gemini 2.5 takes the integer budget, not the
level vocabulary.

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
Gemini 2.5 (C<thinkingBudget>) and Gemini 3 (C<thinkingLevel>) and to clamp
the Gemini 3 level vocabulary to the model family's supported subset.

=cut

has thinking_budget => (
  is        => 'ro',
  isa       => 'Int',
  predicate => 'has_thinking_budget',
);

has thinking_display => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_thinking_display',
);

=attr thinking_display

Optional Anthropic thinking-visibility control, serialized by L</to_anthropic>
as C<thinking.display>. Values: C<summarized> (return a readable summary of the
reasoning), C<omitted> (no summary; the C<thinking> field comes back empty), or
C<updates> (beta; between-tool-call progress notes). On every current Claude
model the API default is C<omitted>, so a caller that wants to read
C<< $response->thinking >> must set C<thinking_display =E<gt> 'summarized'>
explicitly. Consumed only on the C<anthropic> wire; ignored on every other
format. Only takes effect together with a thinking block, i.e. on the adaptive
(non-Fable-class) path — see L</to_anthropic>.

=cut

=attr thinking_budget

Optional integer thinking budget for Gemini 2.5 models. When set on a Gemini
2.5 model (model id starting with C<gemini-2.5>), L</to_gemini> emits
C<thinkingConfig.thinkingBudget> as the integer. Setting C<thinking_budget>
on a Gemini 3 model, or setting it together with C<effort> on any model, is
rejected at construction time (L</BUILD>) — the two fields speak different
units (binary level vs integer tokens) and a combined or wrong-generation wire
form would be ambiguous.

=cut

# OpenAI reasoning effort is gated per MODEL, not per wire. Chat Completions
# `reasoning_effort` and the Responses API `reasoning.effort` $ref the identical
# ReasoningEffort schema (enum none|minimal|low|medium|high|xhigh|max, default
# medium), so a given model accepts the same value set on both wires — to_openai
# and to_responses therefore share the one clamp below (_openai_effort_ok), which
# structurally forbids the two wires diverging. The accepted set is per model
# generation and the generations do NOT overlap: the gpt-5 (legacy) generation
# has `minimal` but rejects none/xhigh/max, while the gpt-5.5+ generation has
# none/xhigh/max but rejects `minimal`. Only OpenAI's own gpt-5.x ids are gated;
# every other id (an unlisted OpenAI model, or another OpenAI-compatible provider
# sharing this wire) keeps the full normalized vocabulary, which IS the current
# OpenAI enum, so no value is dropped from it.
# (developers.openai.com/api/docs/guides/reasoning + the per-model pages,
# advisor-verified 2026-09-01 — karr k140. gpt-5.1's ladder is not among the
# verified families and is deliberately left un-gated: it falls through to the
# full-enum pass-through rather than being clamped on a guess.)
my %OPENAI_MODEL_EFFORT = (
  'gpt-5.6' => { map { $_ => 1 } qw(       none low medium high xhigh max ) },
  'gpt-5.5' => { map { $_ => 1 } qw(       none low medium high xhigh     ) },
  'gpt-5'   => { map { $_ => 1 } qw( minimal   low medium high            ) },
);

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

# Gemini 3 generationConfig.thinkingConfig.thinkingLevel vocabulary is
# minimal|low|medium|high, but which subset a model accepts is model-gated
# (ai.google.dev/gemini-api/docs/thinking level table, verified 2026-09-01 —
# karr k140):
#
#   gemini-3-flash-preview / gemini-3.6-flash / *-flash-lite: minimal low medium high
#   gemini-3.7-flash:                                         low medium high (no minimal)
#   gemini-3.1-pro-*:                                         low medium high (no minimal)
#   gemini-3-pro-*:                                           low high (binary)
#
# The API rejects an unsupported level instead of mapping it, so the
# normalized vocabulary is clamped to the model family's subset here. Models
# outside the gemini-3 line (or no model given) keep the universally-accepted
# low|high collapse. (Gemini 2.5 never reaches this serializer with an effort
# — BUILD gates it onto the thinkingBudget path.) The gemini-3-pro-* branch is
# defensive: the current catalogue ships only gemini-3-pro-image (not a
# thinking text model), but the clamp stays so a returning gemini-3-pro text id
# cannot 400 on minimal/medium.
my %GEMINI3_LEVEL = (
  none    => 'minimal',
  minimal => 'minimal',
  low     => 'low',
  medium  => 'medium',
  high    => 'high',
  xhigh   => 'high',
  max     => 'high',
);

sub to_gemini_level {
  my ( $self ) = @_;
  my $e = $self->effort;
  my $model = $self->has_model ? $self->model : '';

  # Unknown or non-Gemini-3 model: binary low|high collapse, the subset every
  # thinking model accepts.
  return ( $e eq 'high' || $e eq 'xhigh' || $e eq 'max' ) ? 'high' : 'low'
    unless $model =~ /\Agemini-3/;

  my $level = $GEMINI3_LEVEL{$e} // 'low';

  # gemini-3.7-flash dropped `minimal` (low|medium|high); gemini-3.1-pro-* has
  # no minimal; gemini-3-pro-* is low|high only. Clamp down (never up): an
  # unsupported level would be rejected by the API.
  if ( $model =~ /\Agemini-3\.7-flash/ ) {
    $level = 'low' if $level eq 'minimal';
  }
  elsif ( $model =~ /\Agemini-3\.1-pro/ ) {
    $level = 'low' if $level eq 'minimal';
  }
  elsif ( $model =~ /\Agemini-3-pro/ ) {
    $level = 'low' if $level eq 'minimal' || $level eq 'medium';
  }
  return $level;
}

=method to_gemini_level

Maps the normalized effort onto Gemini 3's C<thinkingLevel> vocabulary
(C<minimal>|C<low>|C<medium>|C<high>): C<none>/C<minimal> become C<minimal>,
C<high>/C<xhigh>/C<max> become C<high>, C<low> and C<medium> pass through.
The result is then clamped down to the subset the configured L</model> family
accepts: C<gemini-3.7-flash> and C<gemini-3.1-pro-*> drop C<minimal> to C<low>
(no C<minimal> support), C<gemini-3-pro-*> accepts only C<low>|C<high> and drops
C<minimal> and C<medium> to C<low>. Models outside the Gemini 3 line (or no
model) keep the universally-accepted binary C<low>|C<high> collapse, splitting
at C<high>.

=cut

# Shared per-model effort gate for both OpenAI wires (see %OPENAI_MODEL_EFFORT).
# Returns true when the configured model accepts the current effort. Model ids
# come in families, so match by anchored prefix, most specific first: gpt-5.6-*
# (sol/terra/luna) and gpt-5.5* are the new generation, gpt-5 / gpt-5-* the
# legacy one. gpt-5.1 (and every other unrecognized id) returns true — its
# vocabulary is unverified, so it keeps the full enum rather than a guessed clamp.
sub _openai_effort_ok {
  my ( $self ) = @_;
  my $e     = $self->effort;
  my $model = $self->has_model ? $self->model : '';
  my $set = $model =~ /\Agpt-5\.6/        ? $OPENAI_MODEL_EFFORT{'gpt-5.6'}
          : $model =~ /\Agpt-5\.5/        ? $OPENAI_MODEL_EFFORT{'gpt-5.5'}
          : $model =~ /\Agpt-5(?![.\d])/  ? $OPENAI_MODEL_EFFORT{'gpt-5'}
          :                                 undef;
  return 1 unless defined $set;
  return $set->{$e} ? 1 : 0;
}

sub to_openai {
  my ( $self ) = @_;
  return () unless $self->has_effort;
  return () unless $self->_openai_effort_ok;
  return ( reasoning_effort => $self->effort );
}

sub to_responses {
  my ( $self ) = @_;
  return () unless $self->has_effort;
  return () unless $self->_openai_effort_ok;
  return ( reasoning => { effort => $self->effort } );
}

=method to_openai

=method to_responses

Serialize L</effort> to the two OpenAI wires — Chat Completions
(C<reasoning_effort =E<gt> $effort>) and the Responses API
(C<reasoning =E<gt> { effort =E<gt> $effort }>). Both surfaces C<$ref> the
identical C<ReasoningEffort> schema, so both clamp through the same model-gated
gate: the accepted value set is per model generation
(gpt-5.6-* / gpt-5.5-*: C<none|low|medium|high|xhigh(|max)>, no C<minimal>;
gpt-5 legacy: C<minimal|low|medium|high>, no C<none|xhigh|max>), and an
unrecognized model id keeps the full normalized vocabulary. An effort the
configured L</model> does not accept yields an empty list on B<both> wires —
they can never diverge. Empty list when no L</effort> is set.

=cut

sub to_anthropic {
  my ( $self ) = @_;
  my $e = $self->has_effort ? $self->effort : undef;
  my $effort_ok = defined $e && $ANTHROPIC_EFFORT{$e};

  # Adaptive-thinking models need thinking:{type:adaptive} or thinking stays
  # off; always-on "Fable-class" models 400 on thinking:{type:disabled} and
  # need no thinking field at all (thinking is always on). thinking.display
  # controls visibility: the wire default is "omitted" on every current model,
  # so $response->thinking comes back empty unless the caller asks for
  # "summarized". We emit the thinking block whenever an effort or a display is
  # in play so a display-only request still turns summaries on.
  my @thinking;
  if ( !$self->_is_fable_class && ( $effort_ok || $self->has_thinking_display ) ) {
    @thinking = ( thinking => {
      type => 'adaptive',
      ( $self->has_thinking_display ? ( display => $self->thinking_display ) : () ),
    } );
  }

  return (
    ( $effort_ok ? ( output_config => { effort => $e } ) : () ),
    @thinking,
  );
}

=method to_anthropic

Serializes to the Messages-API reasoning shape: C<output_config.effort> (when
L</effort> maps onto Anthropic's C<low|medium|high|xhigh|max> set) plus a
C<thinking> block. On adaptive (non-Fable-class) models the block is
C<< { type =E<gt> 'adaptive' } >>, carrying C<display =E<gt> ...> when
L</thinking_display> is set. Fable-class models (Fable / Mythos) get no
C<thinking> key — thinking is always on and C<type:disabled> 400s there — and
therefore cannot carry a C<display> either. Empty list when neither an
Anthropic-supported effort nor a C<thinking_display> is present.

=cut

sub to_gemini {
  my ( $self ) = @_;
  if ( $self->has_thinking_budget ) {
    # BUILD has already verified the model is Gemini 2.5.
    return ( thinkingConfig => { thinkingBudget => $self->thinking_budget } );
  }
  return () unless $self->has_effort;
  return ( thinkingConfig => { thinkingLevel => $self->to_gemini_level } );
}

sub to_ollama {
  my ( $self ) = @_;
  return () unless $self->has_effort;
  # Ollama's only reasoning knob is the boolean options.think; the normalized
  # vocabulary collapses onto it (any effort level -> on, 'none' -> off).
  return ( think => $self->effort eq 'none' ? JSON->false : JSON->true );
}

=method to_ollama

Serializes to Ollama's C<options.think> boolean: any effort level other than
C<none> turns thinking on, C<none> turns it off. Empty list when no effort is
set. (Ollama does not compose L<Langertha::Role::ReasoningEffort> — the engine
calls this serializer directly from its C<chat_request> when a per-request
C<reasoning_effort> control arrives.)

=cut

# Maps a reasoning_wire_format tag to the per-format serializer method.
my %TO_METHOD = (
  openai    => 'to_openai',
  responses => 'to_responses',
  anthropic => 'to_anthropic',
  gemini    => 'to_gemini',
  ollama    => 'to_ollama',
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
