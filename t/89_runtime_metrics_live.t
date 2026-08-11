#!/usr/bin/env perl
# ABSTRACT: Live test for Langertha::Role::Runtime::MetricsPoll against a running inference server

use strict;
use warnings;

use Test2::Bundle::More;

# Two modes:
#   1) Pointed at one or more engines via env vars (TEST_LANGERTHA_VLLM_URL,
#      TEST_LANGERTHA_SGLANG_URL, TEST_LANGERTHA_LLAMACPP_URL). Each must
#      serve a real /metrics endpoint. Skip cleanly if none are set.
#   2) Generic TEST_LANGERTHA_RUNTIME_METRICS_URL with no engine match —
#      skipped by default (no engine prefix to test).
BEGIN {
  my %engines = (
    vllm     => $ENV{TEST_LANGERTHA_VLLM_URL},
    sglang   => $ENV{TEST_LANGERTHA_SGLANG_URL},
    llamacpp => $ENV{TEST_LANGERTHA_LLAMACPP_URL},
  );
  my $any_set = grep { defined && length } values %engines;
  unless ($any_set) {
    plan skip_all => 'set TEST_LANGERTHA_VLLM_URL / TEST_LANGERTHA_SGLANG_URL / TEST_LANGERTHA_LLAMACPP_URL to a running server';
  }
}

require Future::AsyncAwait;
require Langertha::Engine::vLLM;
require Langertha::Engine::SGLang;
require Langertha::Engine::LlamaCpp;

# vLLM ---------------------------------------------------------------------

subtest 'vLLM scrape' => sub {
  my $url = $ENV{TEST_LANGERTHA_VLLM_URL};
  if (!defined $url || !length $url) {
    plan skip_all => 'TEST_LANGERTHA_VLLM_URL not set';
    return;
  }
  my $engine = eval { Langertha::Engine::vLLM->new(url => $url) };
  if ($@) { fail "construct: $@"; return; }
  ok($engine->supports('runtime_metrics'),
    'vLLM engine advertises runtime_metrics capability');

  my $records;
  eval {
    require IO::Async::Loop;
    my $loop = IO::Async::Loop->new;
    $records = $loop->await(
      Future->wrap($engine->poll_metrics_f('vllm:'))
    );
  };
  if ($@) { fail "poll_metrics_f: $@"; return; }
  ok(ref($records) eq 'ARRAY', 'vLLM scrape returns ArrayRef');
  diag "vLLM scraped " . scalar(@$records) . " vllm: records";
};

# SGLang --------------------------------------------------------------------

subtest 'SGLang scrape' => sub {
  my $url = $ENV{TEST_LANGERTHA_SGLANG_URL};
  if (!defined $url || !length $url) {
    plan skip_all => 'TEST_LANGERTHA_SGLANG_URL not set';
    return;
  }
  my $engine = eval { Langertha::Engine::SGLang->new(url => $url) };
  if ($@) { fail "construct: $@"; return; }
  ok($engine->supports('runtime_metrics'),
    'SGLang engine advertises runtime_metrics capability');

  my $records;
  eval {
    require IO::Async::Loop;
    my $loop = IO::Async::Loop->new;
    $records = $loop->await(
      Future->wrap($engine->poll_metrics_f('sglang:'))
    );
  };
  if ($@) { fail "poll_metrics_f: $@"; return; }
  ok(ref($records) eq 'ARRAY', 'SGLang scrape returns ArrayRef');
  diag "SGLang scraped " . scalar(@$records) . " sglang: records";
};

# llama.cpp ----------------------------------------------------------------

subtest 'llama.cpp scrape' => sub {
  my $url = $ENV{TEST_LANGERTHA_LLAMACPP_URL};
  if (!defined $url || !length $url) {
    plan skip_all => 'TEST_LANGERTHA_LLAMACPP_URL not set';
    return;
  }
  my $engine = eval { Langertha::Engine::LlamaCpp->new(url => $url) };
  if ($@) { fail "construct: $@"; return; }
  ok($engine->supports('runtime_metrics'),
    'LlamaCpp engine advertises runtime_metrics capability');

  my $records;
  eval {
    require IO::Async::Loop;
    my $loop = IO::Async::Loop->new;
    $records = $loop->await(
      Future->wrap($engine->poll_metrics_f('llama_'))
    );
  };
  if ($@) { fail "poll_metrics_f: $@"; return; }
  ok(ref($records) eq 'ARRAY', 'llama.cpp scrape returns ArrayRef');
  diag "llama.cpp scraped " . scalar(@$records) . " llama_ records";
};

done_testing;
