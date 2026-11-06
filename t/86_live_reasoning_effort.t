#!/usr/bin/env perl
# ABSTRACT: Live integration test for request-side reasoning_effort (karr #16)
#
# COSTS REAL MONEY. Each subtest makes ONE tiny chat call against a real
# provider. Needs TEST_LANGERTHA_LIVE=1 plus the matching
# TEST_LANGERTHA_<ENGINE>_API_KEY (the Anthropic Opus subtest also needs
# TEST_LANGERTHA_LIVE_EXPENSIVE=1); subtests without a key are skipped. Each call uses a reasoning-capable model (the
# non-reasoning engine defaults reject reasoning_effort) and a small
# response_size to keep cost minimal. The point is to confirm the new wire
# shapes are ACCEPTED (HTTP 200), not to assert on model output.

use strict;
use warnings;

use Test2::Bundle::More;

BEGIN {
  plan skip_all => 'set TEST_LANGERTHA_LIVE=1 to run live tests (they spend real money)'
    unless $ENV{TEST_LANGERTHA_LIVE};
  my @available;
  # Cost gate: the Anthropic block pins claude-opus-5-5 (premium tier), opt-in via TEST_LANGERTHA_LIVE_EXPENSIVE.
  push @available, 'anthropic' if $ENV{TEST_LANGERTHA_ANTHROPIC_API_KEY} && $ENV{TEST_LANGERTHA_LIVE_EXPENSIVE};
  push @available, 'openai'    if $ENV{TEST_LANGERTHA_OPENAI_API_KEY};
  push @available, 'gemini'    if $ENV{TEST_LANGERTHA_GEMINI_API_KEY};
  push @available, 'deepseek'  if $ENV{TEST_LANGERTHA_DEEPSEEK_API_KEY};
  unless (@available) {
    plan skip_all => 'no usable provider for the live reasoning_effort test: set TEST_LANGERTHA_*_API_KEY (Anthropic also needs TEST_LANGERTHA_LIVE_EXPENSIVE=1)';
  }
}

# Anthropic — the load-bearing fix: output_config.effort + thinking:{type:adaptive}
SKIP: {
  skip 'no TEST_LANGERTHA_ANTHROPIC_API_KEY', 1
    unless $ENV{TEST_LANGERTHA_ANTHROPIC_API_KEY};
  # Cost gate: claude-opus-5-5 is the premium tier, opt-in only.
  skip 'set TEST_LANGERTHA_LIVE_EXPENSIVE=1 to run the claude-opus-5-5 Anthropic test (premium model, costs money)', 1
    unless $ENV{TEST_LANGERTHA_LIVE_EXPENSIVE};
  require Langertha::Engine::Anthropic;
  my $e = Langertha::Engine::Anthropic->new(
    api_key          => $ENV{TEST_LANGERTHA_ANTHROPIC_API_KEY},
    model            => 'claude-opus-5-5',   # reasoning-capable; effort supported
    reasoning_effort => 'low',
    response_size    => 256,   # room for thinking so the text is not empty
  );
  my $resp = eval { $e->simple_chat('Reply with the single word: ok') };
  ok( $resp && length("$resp"),
    'Anthropic accepts output_config.effort + thinking:{type:adaptive} on claude-opus-5-5' )
    or diag("Anthropic live error: $@");
}

# OpenAI chat completions — flat reasoning_effort on a gpt-5.x reasoning model.
SKIP: {
  skip 'no TEST_LANGERTHA_OPENAI_API_KEY', 1
    unless $ENV{TEST_LANGERTHA_OPENAI_API_KEY};
  require Langertha::Engine::OpenAI;
  my $e = Langertha::Engine::OpenAI->new(
    api_key          => $ENV{TEST_LANGERTHA_OPENAI_API_KEY},
    model            => 'gpt-5.6-luna',   # cheap reasoning model; pinned explicitly
    reasoning_effort => 'low',
    response_size    => 256,   # room for thinking so the text is not empty
  );
  my $resp = eval { $e->simple_chat('Reply with the single word: ok') };
  ok( $resp && length("$resp"),
    'OpenAI accepts flat reasoning_effort on a gpt-5.x reasoning model' )
    or diag("OpenAI live error: $@");
}

# Gemini — generationConfig.thinkingConfig.thinkingLevel on a Gemini 3 model.
SKIP: {
  skip 'no TEST_LANGERTHA_GEMINI_API_KEY', 1
    unless $ENV{TEST_LANGERTHA_GEMINI_API_KEY};
  require Langertha::Engine::Gemini;
  my $e = Langertha::Engine::Gemini->new(
    api_key          => $ENV{TEST_LANGERTHA_GEMINI_API_KEY},
    model            => 'gemini-3.5-flash-lite',
    reasoning_effort => 'high',
    response_size    => 1024,   # thinking tokens count against maxOutputTokens
  );
  my $resp = eval { $e->simple_chat('Reply with the single word: ok') };
  ok( $resp && length("$resp"),
    'Gemini accepts generationConfig.thinkingConfig.thinkingLevel' )
    or diag("Gemini live error: $@");
}

# DeepSeek — V4 flat reasoning_effort (none|low|high|max on deepseek-flash).
SKIP: {
  skip 'no TEST_LANGERTHA_DEEPSEEK_API_KEY', 1
    unless $ENV{TEST_LANGERTHA_DEEPSEEK_API_KEY};
  require Langertha::Engine::DeepSeek;
  my $e = Langertha::Engine::DeepSeek->new(
    api_key          => $ENV{TEST_LANGERTHA_DEEPSEEK_API_KEY},
    model            => 'deepseek-flash',
    reasoning_effort => 'high',
    response_size    => 64,
  );
  my $resp = eval { $e->simple_chat('Reply with the single word: ok') };
  ok( $resp && length("$resp"),
    'DeepSeek V4 accepts flat reasoning_effort high' )
    or diag("DeepSeek live error: $@");
}

# Gemini 2.5 — generationConfig.thinkingConfig.thinkingBudget (integer).
# Model-gated: only Gemini 2.5-* accepts the integer budget (Gemini 3 takes
# thinkingLevel, see subtest above). One tiny call against a 2.5 model
# to confirm the wire shape is ACCEPTED (HTTP 200), not to assert on output.
SKIP: {
  skip 'no TEST_LANGERTHA_GEMINI_API_KEY', 1
    unless $ENV{TEST_LANGERTHA_GEMINI_API_KEY};
  require Langertha::Engine::Gemini;
  my $e = Langertha::Engine::Gemini->new(
    api_key        => $ENV{TEST_LANGERTHA_GEMINI_API_KEY},
    model          => 'gemini-2.5-flash-lite',
    thinking_budget => 512,
    response_size  => 1024,   # thinking tokens count against maxOutputTokens
  );
  my $resp = eval { $e->simple_chat('Reply with the single word: ok') };
  ok( $resp && length("$resp"),
    'Gemini 2.5 accepts generationConfig.thinkingConfig.thinkingBudget' )
    or diag("Gemini 2.5 live error: $@");
}

done_testing;
