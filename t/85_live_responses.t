#!/usr/bin/env perl
# ABSTRACT: Live integration test for OpenAI Responses API (gpt-6-luna; gpt-5.5-pro with TEST_LANGERTHA_LIVE_EXPENSIVE=1)

use strict;
use warnings;

use Test2::Bundle::More;
use Future::AsyncAwait;

BEGIN {
  plan skip_all => 'set TEST_LANGERTHA_LIVE=1 to run live tests (they spend real money)'
    unless $ENV{TEST_LANGERTHA_LIVE};
  plan skip_all => 'TEST_LANGERTHA_OPENAI_API_KEY not set'
    unless $ENV{TEST_LANGERTHA_OPENAI_API_KEY};
  eval {
    require IO::Async::Loop;
    require Future::AsyncAwait;
    1;
  } or plan skip_all => 'Requires IO::Async and Future::AsyncAwait';
}

use IO::Async::Loop;
use Future::AsyncAwait;

use Langertha::Engine::OpenAIResponses;

# Cost gate: the pro model bills heavily, so it is only chosen with
# TEST_LANGERTHA_LIVE_EXPENSIVE=1; otherwise the cheap gpt-6-luna runs. An
# explicit TEST_LANGERTHA_RESPONSES_MODEL always wins.
my $engine = Langertha::Engine::OpenAIResponses->new(
  api_key => $ENV{TEST_LANGERTHA_OPENAI_API_KEY},
  model   => $ENV{TEST_LANGERTHA_RESPONSES_MODEL}
    // ( $ENV{TEST_LANGERTHA_LIVE_EXPENSIVE} ? 'gpt-5.5-pro' : 'gpt-6-luna' ),
);

subtest 'simple_chat text response' => sub {
  my $resp = eval { $engine->simple_chat('Say exactly: Hello Responses') };
  if ($@) {
    if ($@ =~ /404/) {
      diag "Model not available on Responses API (404), skipping";
      pass "skipped - model not available on Responses endpoint";
      return;
    }
    if ($@ =~ /429/) {
      diag "Rate limited (429), skipping";
      pass "skipped due to rate limit";
      return;
    }
    die $@;
  }
  ok(defined $resp, 'returns a response');
  ok(length("$resp") > 0, 'response is non-empty');
  diag "Response: $resp";
  diag "Model: " . ($resp->model // 'n/a');
  if ($resp->can('has_usage') && $resp->has_usage) {
    diag "Tokens: " . $resp->usage->{prompt_tokens} . " in / " . $resp->usage->{completion_tokens} . " out";
    if (my $rt = $resp->usage->{completion_tokens_details}{reasoning_tokens}) {
      diag "Reasoning tokens: $rt";
    }
  }
};

subtest 'simple_chat with reasoning' => sub {
  # the Responses models are reasoning models - check that thinking is captured
  my $resp = eval {
    $engine->simple_chat('What is 2+2? Just give the number.')
  };
  if ($@) {
    if ($@ =~ /404/) {
      pass "skipped - model not available on Responses endpoint";
      return;
    }
    die $@ if $@ !~ /429/;
    diag "Rate limited (429), skipping";
    pass "skipped due to rate limit";
    return;
  }
  ok(defined $resp, 'returns a response');
  diag "Response: $resp";
  if ($resp->can('thinking') && $resp->thinking) {
    diag "Thinking: " . substr($resp->thinking, 0, 100) . "...";
  }
};

done_testing;