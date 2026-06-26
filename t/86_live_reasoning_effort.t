#!/usr/bin/env perl
# ABSTRACT: Live integration test for request-side reasoning_effort (karr #16)
#
# COSTS REAL MONEY. Each subtest makes ONE tiny chat call against a real
# provider, gated on the matching TEST_LANGERTHA_<ENGINE>_API_KEY; subtests
# without a key are skipped. Each call uses a reasoning-capable model (the
# non-reasoning engine defaults reject reasoning_effort) and a small
# response_size to keep cost minimal. The point is to confirm the new wire
# shapes are ACCEPTED (HTTP 200), not to assert on model output.

use strict;
use warnings;

use Test2::Bundle::More;

BEGIN {
  my @available;
  push @available, 'anthropic' if $ENV{TEST_LANGERTHA_ANTHROPIC_API_KEY};
  push @available, 'openai'    if $ENV{TEST_LANGERTHA_OPENAI_API_KEY};
  push @available, 'gemini'    if $ENV{TEST_LANGERTHA_GEMINI_API_KEY};
  push @available, 'deepseek'  if $ENV{TEST_LANGERTHA_DEEPSEEK_API_KEY};
  unless (@available) {
    plan skip_all => 'No TEST_LANGERTHA_* API keys set (live reasoning_effort test)';
  }
}

# Anthropic — the load-bearing fix: output_config.effort + thinking:{type:adaptive}
SKIP: {
  skip 'no TEST_LANGERTHA_ANTHROPIC_API_KEY', 1
    unless $ENV{TEST_LANGERTHA_ANTHROPIC_API_KEY};
  require Langertha::Engine::Anthropic;
  my $e = Langertha::Engine::Anthropic->new(
    api_key          => $ENV{TEST_LANGERTHA_ANTHROPIC_API_KEY},
    model            => 'claude-opus-4-8',   # reasoning-capable; effort supported
    reasoning_effort => 'high',
    response_size    => 64,
  );
  my $resp = eval { $e->simple_chat('Reply with the single word: ok') };
  ok( $resp && length("$resp"),
    'Anthropic accepts output_config.effort + thinking:{type:adaptive} on claude-opus-4-8' )
    or diag("Anthropic live error: $@");
}

# OpenAI chat completions — flat reasoning_effort on a gpt-5.x reasoning model.
SKIP: {
  skip 'no TEST_LANGERTHA_OPENAI_API_KEY', 1
    unless $ENV{TEST_LANGERTHA_OPENAI_API_KEY};
  require Langertha::Engine::OpenAI;
  my $e = Langertha::Engine::OpenAI->new(
    api_key          => $ENV{TEST_LANGERTHA_OPENAI_API_KEY},
    model            => 'gpt-5.1',   # reasoning model; gpt-5.4-mini default rejects effort
    reasoning_effort => 'high',
    response_size    => 64,
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
    model            => 'gemini-3.5-flash',
    reasoning_effort => 'high',
    response_size    => 64,
  );
  my $resp = eval { $e->simple_chat('Reply with the single word: ok') };
  ok( $resp && length("$resp"),
    'Gemini accepts generationConfig.thinkingConfig.thinkingLevel' )
    or diag("Gemini live error: $@");
}

# DeepSeek — V4 flat reasoning_effort (high|max).
SKIP: {
  skip 'no TEST_LANGERTHA_DEEPSEEK_API_KEY', 1
    unless $ENV{TEST_LANGERTHA_DEEPSEEK_API_KEY};
  require Langertha::Engine::DeepSeek;
  my $e = Langertha::Engine::DeepSeek->new(
    api_key          => $ENV{TEST_LANGERTHA_DEEPSEEK_API_KEY},
    model            => 'deepseek-reasoner',   # routes to V4
    reasoning_effort => 'high',
    response_size    => 64,
  );
  my $resp = eval { $e->simple_chat('Reply with the single word: ok') };
  ok( $resp && length("$resp"),
    'DeepSeek V4 accepts flat reasoning_effort high' )
    or diag("DeepSeek live error: $@");
}

done_testing;
