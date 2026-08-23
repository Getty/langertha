#!/usr/bin/env perl
# ABSTRACT: Live test for reasoning_effort on Langertha::Engine::vLLM (karr #79)

use strict;
use warnings;

use Test2::Bundle::More;

# Needs a vLLM server serving a reasoning model (Qwen3 / DeepSeek-R1 / QwQ /
# Gemma 4 / Granite 3.2) that was started with a matching --reasoning-parser.
# The parser flag is server-side and cannot be asserted from here, so the
# reasoning_content checks below diagnose instead of failing. The wire itself
# (reasoning_effort on the request body) is covered offline by
# t/65c_vllm_reasoning.t - this file only exercises the round trip.
BEGIN {
  unless ($ENV{TEST_LANGERTHA_VLLM_URL} && $ENV{TEST_LANGERTHA_VLLM_REASONING_MODEL}) {
    plan skip_all => 'TEST_LANGERTHA_VLLM_URL and TEST_LANGERTHA_VLLM_REASONING_MODEL not set';
  }
}

require Langertha::Engine::vLLM;

my $url    = $ENV{TEST_LANGERTHA_VLLM_URL};
my $model  = $ENV{TEST_LANGERTHA_VLLM_REASONING_MODEL};
my $prompt = 'Solve step by step: what is 7 factorial?';

# A reasoning model spends tokens on the thought before the answer; without a
# roomy budget the visible content can come back empty for reasons that have
# nothing to do with reasoning_effort.
my $response_size = 2048;

# Set by the reasoning_effort=high subtest, read by the =none cross-check.
my $saw_thinking_high;

# --- Thinking path: reasoning_effort=high on a hard problem ---
subtest 'reasoning_effort=high' => sub {
  my $engine = Langertha::Engine::vLLM->new(
    url              => $url,
    model            => $model,
    reasoning_effort => 'high',
    response_size    => $response_size,
  );
  my $resp = eval { $engine->simple_chat($prompt) };
  if ($@) {
    fail "simple_chat with reasoning_effort=high failed: $@";
    return;
  }
  ok(defined $resp, 'returns a response');
  ok(length("$resp") > 0, 'response is non-empty');
  diag "model: " . ($resp->has_model ? $resp->model : '(not reported)');
  diag "response: $resp";

  # reasoning_content is lifted onto Langertha::Response->thinking by
  # Langertha::Role::OpenAICompatible->chat_response. It only arrives when the
  # server runs --reasoning-parser <qwen3|deepseek_r1|...> matching the model.
  $saw_thinking_high = ($resp->has_thinking && length $resp->thinking) ? 1 : 0;
  if ($saw_thinking_high) {
    ok($resp->thinking, 'reasoning_content surfaced on Response->thinking');
    diag "thinking (" . length($resp->thinking) . " chars): "
      . substr($resp->thinking, 0, 200);
  }
  else {
    diag "no reasoning_content - was the server started with a "
      . "--reasoning-parser matching $model?";
    pass 'thinking extraction path exercised (server returned none)';
  }
};

# --- Non-thinking path: reasoning_effort=none ---
subtest 'reasoning_effort=none' => sub {
  my $engine = Langertha::Engine::vLLM->new(
    url              => $url,
    model            => $model,
    reasoning_effort => 'none',
    response_size    => $response_size,
  );
  my $resp = eval { $engine->simple_chat($prompt) };
  if ($@) {
    fail "simple_chat with reasoning_effort=none failed: $@";
    return;
  }
  ok(defined $resp, 'returns a response');
  ok(length("$resp") > 0, 'response is non-empty');
  diag "response: $resp";

  my $saw_thinking_none = ($resp->has_thinking && length $resp->thinking) ? 1 : 0;

  if (!defined $saw_thinking_high) {
    diag "no high-effort result to cross-check against";
    return;
  }
  if ($saw_thinking_high && !$saw_thinking_none) {
    ok(!$saw_thinking_none,
      'reasoning_effort=none suppressed the thinking that high produced');
  }
  elsif ($saw_thinking_high) {
    diag "server still emitted reasoning_content for reasoning_effort=none - "
      . "some vLLM builds do not map 'none' onto enable_thinking=false "
      . "(see the note in t/65c_vllm_reasoning.t)";
    pass 'non-thinking path exercised (server did not honour none)';
  }
  else {
    diag "high effort produced no thinking either - nothing to cross-check";
    pass 'non-thinking path exercised (no reasoning parser on the server)';
  }
};

done_testing;
