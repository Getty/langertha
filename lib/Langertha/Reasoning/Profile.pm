package Langertha::Reasoning::Profile;
# ABSTRACT: Typed per-model reasoning wire-truth (accepted vocabulary + numeric bounds)
our $VERSION = '0.503';
use Moose;
use Moose::Util::TypeConstraints;
use Carp qw( croak );

=head1 SYNOPSIS

    my $profile = Langertha::Reasoning::Profile->for_model('gpt-5.6-terra');
    $profile->control;                          # 'effort'
    $profile->effort_accepted_on('openai', 'max');  # 1

=head1 DESCRIPTION

Immutable value object holding what a reasoning model's wire literally accepts —
the linchpin datatype behind L<Langertha::Reasoning>. It carries the two
non-overridable categories from karr k173's three-category taxonomy: the
B<accepted vocabulary + native control type> (which levels the wire takes,
effort/budget/boolean) and the B<provider-enforced numeric bounds & magic
values> (Gemini 2.5's budget floor/ceiling, C<0>=off, C<-1>=dynamic). The
invented level-to-token interpolation (category c) is deliberately absent — it
belongs in a later C<BudgetPolicy>, clamped to this object's bounds.

L</for_model> resolves an id to its profile most-specific-first (exact id →
family regex → provider default), replacing the scattered per-model hashes and
regexes that used to live inline in L<Langertha::Reasoning>. Each profile
carries a C<source> receipt (doc URL + verification date) so curating a new
family is a single declarative add.

=cut

# The normalized ascending reasoning vocabulary, defined ONCE and reused. A
# namespaced type name so it cannot collide with any other 'ReasoningLevel'
# registered in the process (Moose croaks on enum-name redefinition).
enum 'Langertha::Reasoning::Level'
  => [qw( none minimal low medium high xhigh max )];
enum 'Langertha::Reasoning::Control'
  => [qw( effort budget boolean none )];
enum 'Langertha::Reasoning::DisableForm'
  => [qw( absent explicit_none think_false budget_zero )];
enum 'Langertha::Reasoning::Wire'
  => [qw( openai responses anthropic gemini ollama )];

# The Anthropic Messages-API output_config.effort vocabulary — uniform across
# every current Claude model (the normalized none/minimal have no Anthropic
# equivalent and drop). A wire-level fact, so to_anthropic checks it directly
# rather than the per-model resolved levels.
my @ANTHROPIC_EFFORT_LEVELS = qw( low medium high xhigh max );
my %ANTHROPIC_EFFORT_SET    = map { $_ => 1 } @ANTHROPIC_EFFORT_LEVELS;

# Normalized effort -> Gemini 3 thinkingLevel base vocabulary
# (minimal|low|medium|high); then clamped down to the family's accepted subset.
my %GEMINI_BASE = (
  none    => 'minimal',
  minimal => 'minimal',
  low     => 'low',
  medium  => 'medium',
  high    => 'high',
  xhigh   => 'high',
  max     => 'high',
);
my %GEMINI_ORDER = ( minimal => 0, low => 1, medium => 2, high => 3 );

has model_match => (
  is  => 'ro',
  isa => 'Str | RegexpRef',
);

=attr model_match

The id or family pattern this profile matches — an exact C<Str> id or a
C<RegexpRef> family pattern. Descriptive; L</for_model> tests the registry's
matchers in order.

=cut

has control => (
  is       => 'ro',
  isa      => 'Langertha::Reasoning::Control',
  required => 1,
);

=attr control

The wire's native reasoning control type: C<effort> (a level string),
C<budget> (an integer token budget, Gemini 2.5), C<boolean> (Ollama's
C<options.think>) or C<none>.

=cut

has levels => (
  is      => 'ro',
  isa     => 'ArrayRef[Langertha::Reasoning::Level]',
  default => sub { [] },
);

=attr levels

The on-spectrum vocabulary the wire literally accepts, ascending. Empty for
C<budget>/C<boolean> controls (quantization anchors are not wire-truth). For a
Gemini 3 family it is the accepted C<thinkingLevel> subset.

=cut

has levels_by_wire => (
  is      => 'ro',
  isa     => 'HashRef[ArrayRef[Langertha::Reasoning::Level]]',
  default => sub { {} },
);

=attr levels_by_wire

Per-wire refinement of L</levels> for a family whose accepted set differs
between the wires it speaks (the OpenAI C<openai> vs C<responses> axis, karr
k176). The gpt-6 and gpt-5.6 generations drop C<max> on the C<openai> (Chat
Completions) wire while keeping it on C<responses> — C<max> is Responses-only
(live-confirmed 2026-09-16, karr k176). A family whose wires agree populates
both keys with the same set; the unlisted-id default leaves it empty (no
per-wire restriction).

=cut

has can_disable => (
  is      => 'ro',
  isa     => 'Bool',
  default => 1,
);

=attr can_disable

Whether reasoning can be turned off on this model. C<0> marks the always-on
"Fable-class" Anthropic models, where C<thinking:{type:disabled}> 400s and no
C<thinking> field may be sent.

=cut

has disable_form => (
  is      => 'ro',
  isa     => 'Langertha::Reasoning::DisableForm',
  default => 'absent',
);

=attr disable_form

How "off" is expressed on the wire: C<absent> (omit the field),
C<explicit_none> (the literal C<none> level), C<think_false> (Ollama) or
C<budget_zero> (Gemini flash C<thinkingBudget=0>).

=cut

has wire_format => (
  is       => 'ro',
  isa      => 'Langertha::Reasoning::Wire',
  required => 1,
);

=attr wire_format

The reasoning dialect this model's family primarily speaks. Descriptive: the
serialization is still selected by the caller's C<reasoning_wire_format> (an
OpenAI-compatible engine may run a non-gpt model on the C<openai> wire), so it
is a curation hint, not the dispatch key.

=cut

has is_gemini3 => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

=attr is_gemini3

Selects the Gemini serialization branch: true for the Gemini 3 family (map onto
C<thinkingLevel> then clamp to L</levels>), false for everything else (the
universally-accepted binary C<low>|C<high> collapse a non-Gemini-3 model takes).

=cut

for my $bound (qw( budget_min budget_max off_value dynamic_value )) {
  has $bound => (
    is        => 'ro',
    isa       => 'Int',
    predicate => 'has_' . $bound,
  );
}

=attr budget_min

=attr budget_max

Provider-enforced integer C<thinkingBudget> bounds for a C<budget>-control
family (Gemini 2.5). Category (b) wire-truth: a later BudgetPolicy may only emit
values inside them. Carried but not enforced in Phase 1 (the value passes
through verbatim, as today).

=cut

=attr off_value

The magic C<thinkingBudget> that disables thinking (Gemini flash / flash-lite:
C<0>); C<undef> where the family cannot disable (Gemini 2.5 pro).

=cut

=attr dynamic_value

The magic C<thinkingBudget> that hands budget selection to the model (Gemini:
C<-1>).

=cut

has source => (
  is      => 'ro',
  isa     => 'Str',
  default => '',
);

=attr source

The curation receipt — provider doc URL plus verification date — for the
accepted vocabulary and numeric bounds this profile encodes.

=cut

=method fable_class

True for the always-on Anthropic "Fable-class" models (the inverse of
L</can_disable>): they carry an effort but never a C<thinking> block.

=cut

sub fable_class { return $_[0]->can_disable ? 0 : 1 }

=method effort_accepted_on

    $profile->effort_accepted_on('openai', 'max')

Whether the given effort is accepted on the named OpenAI wire (C<openai> or
C<responses>). A family without a per-wire restriction (every non-gpt family and
the unlisted-id default) returns true for every effort — the full normalized
enum passes through, which is the current OpenAI enum. A restricted gpt family
checks membership in its L</levels_by_wire> set for that wire.

=cut

sub effort_accepted_on {
  my ( $self, $wire, $effort ) = @_;
  my $set = $self->levels_by_wire->{$wire};
  return 1 unless defined $set;
  return ( grep { $_ eq $effort } @$set ) ? 1 : 0;
}

=method anthropic_effort_ok

Whether the effort maps onto Anthropic's C<output_config.effort> vocabulary
(C<low|medium|high|xhigh|max>). A wire-level fact, uniform across Claude models.

=cut

sub anthropic_effort_ok {
  my ( $self, $effort ) = @_;
  return $ANTHROPIC_EFFORT_SET{$effort} ? 1 : 0;
}

=method gemini_level_for

    $profile->gemini_level_for('max')   # -> 'high'

Maps the normalized effort onto the Gemini C<thinkingLevel> this model accepts.
A non-Gemini-3 family (L</is_gemini3> false) collapses to the universally
accepted binary C<low>|C<high> at C<high>. A Gemini 3 family maps onto the
C<minimal>|C<low>|C<medium>|C<high> base vocabulary then clamps down to its
L</levels> subset (never up — an unsupported level 400s), a level below the
family's floor rising to that floor.

=cut

sub gemini_level_for {
  my ( $self, $effort ) = @_;
  unless ( $self->is_gemini3 ) {
    return ( $effort eq 'high' || $effort eq 'xhigh' || $effort eq 'max' )
      ? 'high' : 'low';
  }
  my $level = $GEMINI_BASE{$effort} // 'low';
  return $self->_clamp_gemini_level($level);
}

# Clamp a base Gemini level down to the profile's accepted set: keep it if
# accepted, else drop to the highest accepted level below it, or rise to the
# lowest accepted level when it sits below the family's floor. The accepted sets
# are contiguous ranges, so this reproduces the family clamps exactly.
sub _clamp_gemini_level {
  my ( $self, $level ) = @_;
  my %ok = map { $_ => 1 } @{ $self->levels };
  return $level if $ok{$level};
  my @sorted = sort { $GEMINI_ORDER{$a} <=> $GEMINI_ORDER{$b} }
    grep { defined $GEMINI_ORDER{$_} } @{ $self->levels };
  my $target = $GEMINI_ORDER{$level};
  my $result;
  for my $lvl (@sorted) {
    $result = $lvl if $GEMINI_ORDER{$lvl} < $target;
  }
  return defined $result ? $result : $sorted[0];
}

# ---------------------------------------------------------------------------
# The registry — one ordered, most-specific-first table. Built lazily so the
# class is fully defined (and immutable) before any profile is constructed.
# ---------------------------------------------------------------------------
my @REGISTRY;
my $DEFAULT;

# developers.openai.com/api/docs/guides/reasoning + per-model pages,
# advisor-verified 2026-09-01 (karr k140); gpt-6-astra 2026-09-14 (karr k151).
my $OPENAI_SRC = 'developers.openai.com/api/docs/guides/reasoning; k140 2026-09-01, gpt-6 k151 2026-09-14';
# ai.google.dev/gemini-api/docs/thinking level table, verified 2026-09-01
# (karr k140); gemini-3.8-flash 2026-09-14 (karr k153).
my $GEMINI3_SRC = 'ai.google.dev/gemini-api/docs/thinking; k140 2026-09-01, 3.8-flash k153 2026-09-14';
# ai.google.dev/gemini-api/docs/thinking budget table (2.5), advisor-verified
# 2026-09-16 (karr k173).
my $GEMINI25_SRC = 'ai.google.dev/gemini-api/docs/thinking budget table; k173 2026-09-16';

# karr k176: 'max' is Responses-only for the gpt-6 and gpt-5.6 generations. The
# gpt-5.6 split is live-confirmed (2026-09-16 on gpt-5.6-terra): Chat Completions
# reasoning_effort=max -> HTTP 400 ("Supported values are: 'none', 'low',
# 'medium', 'high', and 'xhigh'."), Responses reasoning.effort=max -> HTTP 200.
# The gpt-6 split is doc-sourced (advisor Azure mirror, same Responses-only-max
# pattern) — not live-probed.
my $OPENAI_K176_LIVE = "$OPENAI_SRC; k176 2026-09-16 live gpt-5.6-terra: chat reasoning_effort=max->400, responses reasoning.effort=max->200";
my $OPENAI_K176_DOC  = "$OPENAI_SRC; k176 gpt-6 max Responses-only (advisor Azure mirror, doc-sourced, not live-probed)";

# $levels is the superset a family accepts on the `responses` (Responses API)
# wire; $extra{openai_levels} is the narrower Chat Completions set, defaulting to
# $levels when the two wires agree. The k176 per-wire max split is exactly this
# openai_levels-vs-levels divergence for the gpt-6 / gpt-5.6 generations.
sub _openai_profile {
  my ( $match, $levels, %extra ) = @_;
  my $openai_levels = delete $extra{openai_levels} // $levels;
  return __PACKAGE__->new(
    model_match    => $match,
    control        => 'effort',
    wire_format    => 'openai',
    levels         => $levels,
    levels_by_wire => { openai => $openai_levels, responses => $levels },
    source         => $OPENAI_SRC,
    %extra,
  );
}

sub _gemini3_profile {
  my ( $match, $levels ) = @_;
  return __PACKAGE__->new(
    model_match => $match,
    control     => 'effort',
    wire_format => 'gemini',
    is_gemini3  => 1,
    levels      => $levels,
    source      => $GEMINI3_SRC,
  );
}

sub _ensure_registry {
  return if @REGISTRY;

  @REGISTRY = (
    # Anthropic always-on Fable/Mythos: matched before the generic claude
    # family. Case-insensitive substring, mirroring the legacy _is_fable_class.
    __PACKAGE__->new(
      model_match  => qr/fable|mythos/i,
      control      => 'effort',
      wire_format  => 'anthropic',
      levels       => [@ANTHROPIC_EFFORT_LEVELS],
      can_disable  => 0,
      disable_form => 'absent',
      source       => 'Anthropic Messages API; Fable/Mythos always-on thinking, k173 2026-09-16',
    ),

    # OpenAI generation ladders. gpt-6 (astra): no none/minimal. gpt-5.6 /
    # gpt-5.5: none but no minimal. Legacy gpt-5: minimal but no none/xhigh/max
    # — the gpt-5(?![.\d]) negative-lookahead keeps it off gpt-5.5/5.6/5.1.
    # gpt-6 and gpt-5.6 carry a per-wire split (karr k176): 'max' is
    # Responses-only, so their openai (Chat Completions) set drops max while the
    # responses set (== levels) keeps it. gpt-5.6 live-confirmed, gpt-6 doc-sourced.
    _openai_profile( qr/\Agpt-6/,
      [qw( low medium high xhigh max )],
      openai_levels => [qw( low medium high xhigh )],
      source        => $OPENAI_K176_DOC,
      disable_form => 'absent', can_disable => 1 ),
    _openai_profile( qr/\Agpt-5\.6/,
      [qw( none low medium high xhigh max )],
      openai_levels => [qw( none low medium high xhigh )],
      source        => $OPENAI_K176_LIVE,
      disable_form => 'explicit_none' ),
    _openai_profile( qr/\Agpt-5\.5/,
      [qw( none low medium high xhigh )], disable_form => 'explicit_none' ),
    _openai_profile( qr/\Agpt-5(?![.\d])/,
      [qw( minimal low medium high )], disable_form => 'absent' ),

    # Gemini 2.5: integer thinkingBudget (no level vocabulary). Category (b)
    # bounds carried but not enforced in Phase 1 (the value passes through).
    __PACKAGE__->new(
      model_match => qr/\Agemini-2\.5-flash-lite/,
      control => 'budget', wire_format => 'gemini', levels => [],
      budget_min => 512, budget_max => 24576, off_value => 0, dynamic_value => -1,
      disable_form => 'budget_zero', source => $GEMINI25_SRC,
    ),
    __PACKAGE__->new(
      model_match => qr/\Agemini-2\.5-flash/,
      control => 'budget', wire_format => 'gemini', levels => [],
      budget_min => 0, budget_max => 24576, off_value => 0, dynamic_value => -1,
      disable_form => 'budget_zero', source => $GEMINI25_SRC,
    ),
    __PACKAGE__->new(
      model_match => qr/\Agemini-2\.5-pro/,
      control => 'budget', wire_format => 'gemini', levels => [],
      budget_min => 128, budget_max => 32768, dynamic_value => -1, can_disable => 0,
      disable_form => 'absent', source => $GEMINI25_SRC,
    ),
    __PACKAGE__->new(
      model_match => qr/\Agemini-2\.5/,
      control => 'budget', wire_format => 'gemini', levels => [],
      budget_min => 0, budget_max => 24576, off_value => 0, dynamic_value => -1,
      disable_form => 'budget_zero', source => $GEMINI25_SRC,
    ),

    # Gemini 3 thinkingLevel families, most-specific-first: 3.7/3.8-flash and
    # 3.1-pro drop minimal (low|medium|high); 3-pro is binary (low|high); every
    # other gemini-3 keeps the full minimal..high set.
    _gemini3_profile( qr/\Agemini-3\.[78]-flash/, [qw( low medium high )] ),
    _gemini3_profile( qr/\Agemini-3\.1-pro/,      [qw( low medium high )] ),
    _gemini3_profile( qr/\Agemini-3-pro/,         [qw( low high )] ),
    _gemini3_profile( qr/\Agemini-3/,             [qw( minimal low medium high )] ),

    # Generic Claude family (adaptive thinking, can disable).
    __PACKAGE__->new(
      model_match => qr/\Aclaude/,
      control     => 'effort',
      wire_format => 'anthropic',
      levels      => [@ANTHROPIC_EFFORT_LEVELS],
      source      => 'Anthropic Messages API output_config.effort; k173 2026-09-16',
    ),
  );

  # Provider default: an unrecognized id keeps the full normalized enum on the
  # openai wire (no per-wire restriction), takes the fixed set on anthropic, and
  # the binary collapse on gemini. Shared by every OpenAI-compatible provider
  # (and no model at all).
  $DEFAULT = __PACKAGE__->new(
    model_match => '',
    control     => 'effort',
    wire_format => 'openai',
    levels      => [@ANTHROPIC_EFFORT_LEVELS],
    source      => 'normalized OpenAI superset passthrough (unlisted id)',
  );

  return;
}

=method for_model

    my $profile = Langertha::Reasoning::Profile->for_model('gemini-3-pro-preview');

Resolve a model id to its profile, matched most-specific-first: an exact id, a
family regex, then the provider default (which every unlisted id and the
no-model case falls through to). Never dies.

=cut

sub for_model {
  my ( $class, $id ) = @_;
  _ensure_registry();
  $id = '' unless defined $id;
  for my $profile (@REGISTRY) {
    my $match = $profile->model_match;
    if ( ref $match eq 'Regexp' ) {
      return $profile if $id =~ $match;
    }
    elsif ( defined $match && length $match ) {
      return $profile if $id eq $match;
    }
  }
  return $DEFAULT;
}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Reasoning> - The value object that resolves and consumes profiles

=item * L<Langertha::Role::ReasoningEffort> - The composed role dispatching to L<Langertha::Reasoning>

=back

=cut

1;
