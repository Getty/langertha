#!/usr/bin/env perl
# ABSTRACT: Characterization matrix locking Langertha::Reasoning wire output (karr k173)

# Golden-master matrix for the reasoning-profile refactor (karr k173 Phase 1).
# Captured BEFORE the internal Profile extraction and asserted to stay
# byte-identical THROUGH it. Every (model, effort/budget) -> wire kwargs pair
# below is the output the value object produces TODAY, tested on each model's
# NATURAL wire (the wire the model's engine actually speaks) — the cross-wire
# combinations an engine never issues are deliberately not pinned.
#
# This test INTENTIONALLY locks two behaviours that Phase 1.5 will change:
#   - gpt-5.6 reasoning_effort=max reaching the Chat Completions wire (#176),
#   - the shared (not per-wire) openai/responses clamp (#176).
# Do NOT "fix" them here; a Phase 1.5 edit flips exactly one row each, cited to
# its live probe.

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;

use Langertha::Reasoning;

# Read the exact kwargs the value object emits for a wire, as a hashref.
sub kw {
  my ( $fmt, %args ) = @_;
  return { Langertha::Reasoning->new(%args)->to($fmt) };
}

my @EFFORTS = qw( none minimal low medium high xhigh max );

# ---------------------------------------------------------------------------
# openai + responses wires: model-gated ladder, shared across both wires today.
# undef = the effort was clamped away (empty kwargs).
# ---------------------------------------------------------------------------
my %OPENAI_LADDER = (
  'gpt-6-astra'   => { none => undef, minimal => undef, low => 'low', medium => 'medium', high => 'high', xhigh => 'xhigh', max => 'max' },
  'gpt-5.6-terra' => { none => 'none', minimal => undef, low => 'low', medium => 'medium', high => 'high', xhigh => 'xhigh', max => 'max' },
  'gpt-5.5'       => { none => 'none', minimal => undef, low => 'low', medium => 'medium', high => 'high', xhigh => 'xhigh', max => undef },
  'gpt-5'         => { none => undef, minimal => 'minimal', low => 'low', medium => 'medium', high => 'high', xhigh => undef, max => undef },
  # gpt-5.1 is deliberately un-gated today (the negative-lookahead spares it):
  # the whole normalized enum passes through on both wires.
  'gpt-5.1'       => { none => 'none', minimal => 'minimal', low => 'low', medium => 'medium', high => 'high', xhigh => 'xhigh', max => 'max' },
);

for my $model ( sort keys %OPENAI_LADDER ) {
  for my $effort ( @EFFORTS ) {
    my $want = $OPENAI_LADDER{$model}{$effort};
    my $chat = kw( 'openai',    effort => $effort, model => $model );
    my $resp = kw( 'responses', effort => $effort, model => $model );
    if ( defined $want ) {
      is_deeply( $chat, { reasoning_effort => $want },
        "openai:    $model + $effort -> reasoning_effort=$want" );
      is_deeply( $resp, { reasoning => { effort => $want } },
        "responses: $model + $effort -> reasoning.effort=$want" );
    }
    else {
      is_deeply( $chat, {}, "openai:    $model + $effort -> DROP" );
      is_deeply( $resp, {}, "responses: $model + $effort -> DROP" );
    }
  }
}

# No model on the openai wire: full-enum passthrough (unrecognized id keeps all).
is_deeply( kw( 'openai', effort => 'max' ), { reasoning_effort => 'max' },
  'openai: no model keeps the full enum (max passes through)' );

# ---------------------------------------------------------------------------
# anthropic wire: fixed effort set low|medium|high|xhigh|max + adaptive thinking
# block; Fable-class models carry effort but never a thinking block.
# ---------------------------------------------------------------------------
{
  my %ADAPTIVE = ( none => undef, minimal => undef,
    low => 'low', medium => 'medium', high => 'high', xhigh => 'xhigh', max => 'max' );
  for my $effort ( @EFFORTS ) {
    my $got  = kw( 'anthropic', effort => $effort, model => 'claude-opus-4-8' );
    my $eff  = $ADAPTIVE{$effort};
    my $want = defined $eff
      ? { output_config => { effort => $eff }, thinking => { type => 'adaptive' } }
      : {};
    is_deeply( $got, $want, "anthropic: claude-opus-4-8 + $effort" );

    my $fab  = kw( 'anthropic', effort => $effort, model => 'claude-fable-5-1' );
    my $fwant = defined $eff ? { output_config => { effort => $eff } } : {};
    is_deeply( $fab, $fwant, "anthropic: claude-fable-5-1 + $effort (no thinking block)" );
  }

  # thinking_display rides on the adaptive block (and turns it on alone).
  is_deeply(
    kw( 'anthropic', effort => 'high', thinking_display => 'summarized', model => 'claude-opus-4-8' ),
    { output_config => { effort => 'high' }, thinking => { type => 'adaptive', display => 'summarized' } },
    'anthropic: effort + display -> both fields' );
  is_deeply(
    kw( 'anthropic', thinking_display => 'summarized', model => 'claude-opus-4-8' ),
    { thinking => { type => 'adaptive', display => 'summarized' } },
    'anthropic: display-only turns on an adaptive block, no output_config' );
  # Fable-class: display cannot ride (no thinking block at all).
  is_deeply(
    kw( 'anthropic', effort => 'high', thinking_display => 'summarized', model => 'claude-fable-5-1' ),
    { output_config => { effort => 'high' } },
    'anthropic: fable-class drops display (no thinking block)' );
}

# ---------------------------------------------------------------------------
# gemini wire (effort path): thinkingConfig.thinkingLevel, per-family clamp.
# ---------------------------------------------------------------------------
my %GEMINI_LEVEL = (
  'gemini-3-pro-preview' => { none => 'low', minimal => 'low', low => 'low', medium => 'low',    high => 'high', xhigh => 'high', max => 'high' },
  'gemini-3.7-flash'     => { none => 'low', minimal => 'low', low => 'low', medium => 'medium', high => 'high', xhigh => 'high', max => 'high' },
  'gemini-3.6-flash'     => { none => 'minimal', minimal => 'minimal', low => 'low', medium => 'medium', high => 'high', xhigh => 'high', max => 'high' },
  # Non-gemini-3 model: universally-accepted binary low|high collapse.
  'gemini-2.0-flash'     => { none => 'low', minimal => 'low', low => 'low', medium => 'low',    high => 'high', xhigh => 'high', max => 'high' },
);

for my $model ( sort keys %GEMINI_LEVEL ) {
  for my $effort ( @EFFORTS ) {
    my $want = $GEMINI_LEVEL{$model}{$effort};
    is_deeply( kw( 'gemini', effort => $effort, model => $model ),
      { thinkingConfig => { thinkingLevel => $want } },
      "gemini: $model + $effort -> thinkingLevel=$want" );
  }
}

# No model on the gemini wire: same binary collapse as a non-gemini-3 model.
is_deeply( kw( 'gemini', effort => 'medium' ),
  { thinkingConfig => { thinkingLevel => 'low' } },
  'gemini: no model medium -> low (binary fallback)' );
is_deeply( kw( 'gemini', effort => 'max' ),
  { thinkingConfig => { thinkingLevel => 'high' } },
  'gemini: no model max -> high (binary fallback)' );

# ---------------------------------------------------------------------------
# gemini wire (budget path): thinkingConfig.thinkingBudget passes the integer
# through verbatim (no Phase-1 clamping).
# ---------------------------------------------------------------------------
is_deeply( kw( 'gemini', thinking_budget => 2048, model => 'gemini-2.5-pro' ),
  { thinkingConfig => { thinkingBudget => 2048 } },
  'gemini: gemini-2.5-pro thinking_budget=2048 passes through' );
is_deeply( kw( 'gemini', thinking_budget => 512, model => 'gemini-2.5-flash' ),
  { thinkingConfig => { thinkingBudget => 512 } },
  'gemini: gemini-2.5-flash thinking_budget=512 passes through' );

# ---------------------------------------------------------------------------
# ollama wire: boolean options.think collapse (any effort -> on, none -> off).
# ---------------------------------------------------------------------------
{
  my $json = JSON::MaybeXS->new;
  for my $effort (qw( minimal low medium high xhigh max )) {
    my $got = kw( 'ollama', effort => $effort, model => 'gpt-oss' );
    ok( exists $got->{think} && $got->{think}, "ollama: $effort -> think=true" );
  }
  my $off = kw( 'ollama', effort => 'none', model => 'gpt-oss' );
  ok( exists $off->{think} && !$off->{think}, 'ollama: none -> think=false' );
  is_deeply( kw( 'ollama' ), {}, 'ollama: no effort -> nothing emitted' );
}

# ---------------------------------------------------------------------------
# BUILD wire-truth gates: exactly one native control per generation.
# ---------------------------------------------------------------------------
like( eval { Langertha::Reasoning->new( effort => 'high', thinking_budget => 2048, model => 'gemini-3.5-flash' ); 1 } ? '' : $@,
  qr/mutually exclusive/i, 'BUILD: effort + thinking_budget croaks (mutually exclusive)' );
like( eval { Langertha::Reasoning->new( thinking_budget => 2048, model => 'claude-opus-4-8' ); 1 } ? '' : $@,
  qr/only valid on Gemini 2\.5/i, 'BUILD: thinking_budget on a non-Gemini-2.5 model croaks' );
like( eval { Langertha::Reasoning->new( thinking_budget => 2048, model => 'gemini-3.5-flash' ); 1 } ? '' : $@,
  qr/only valid on Gemini 2\.5/i, 'BUILD: thinking_budget on Gemini 3 croaks' );
like( eval { Langertha::Reasoning->new( effort => 'high', model => 'gemini-2.5-pro' ); 1 } ? '' : $@,
  qr/not valid on Gemini 2\.5/i, 'BUILD: effort on Gemini 2.5 croaks' );

done_testing;
