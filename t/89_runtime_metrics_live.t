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

# OTLP export --------------------------------------------------------------
# Gated on TEST_LANGERTHA_OTLP_ENDPOINT (any OTLP/HTTP metrics receiver —
# OpenTelemetry Collector, Prometheus OTLP receiver, Grafana). Note: Langfuse
# accepts OTLP metrics POSTs but discards them (no metrics ingestion; see
# Langertha::Runtime::Metrics::OTLP POD), so a Langfuse /api/public/otel
# endpoint would return 2xx here without storing anything.

subtest 'OTLP export to TEST_LANGERTHA_OTLP_ENDPOINT' => sub {
  my $endpoint = $ENV{TEST_LANGERTHA_OTLP_ENDPOINT};
  if (!defined $endpoint || !length $endpoint) {
    plan skip_all => 'TEST_LANGERTHA_OTLP_ENDPOINT not set';
    return;
  }

  # Pick the first configured engine to scrape from.
  my %engines = (
    vllm     => [ $ENV{TEST_LANGERTHA_VLLM_URL},      'Langertha::Engine::vLLM',     'vllm:', 'TEST_LANGERTHA_VLLM_URL' ],
    sglang   => [ $ENV{TEST_LANGERTHA_SGLANG_URL},    'Langertha::Engine::SGLang',   'sglang:', 'TEST_LANGERTHA_SGLANG_URL' ],
    llamacpp => [ $ENV{TEST_LANGERTHA_LLAMACPP_URL},  'Langertha::Engine::LlamaCpp', 'llama_', 'TEST_LANGERTHA_LLAMACPP_URL' ],
  );
  my ($class, $prefix, $url_env);
  for my $key (qw( vllm sglang llamacpp )) {
    my ($url, $c, $p, $env) = @{ $engines{$key} };
    if (defined $url && length $url) { ($class, $prefix, $url_env) = ($c, $p, $env); last; }
  }
  if (!$class) {
    plan skip_all => 'no engine URL configured to scrape from';
    return;
  }

  my $engine = eval { $class->new(url => $ENV{$url_env}) };
  if ($@) { fail "construct $class: $@"; return; }

  my $records;
  eval {
    require IO::Async::Loop;
    my $loop = IO::Async::Loop->new;
    $records = $loop->await(
      Future->wrap($engine->poll_metrics_f($prefix))
    );
  };
  if ($@) { fail "poll_metrics_f: $@"; return; }
  ok(ref($records) eq 'ARRAY' && @$records, "scraped " . scalar(@$records) . " records");

  my $response;
  eval {
    require IO::Async::Loop;
    my $loop = IO::Async::Loop->new;
    $response = $loop->await(
      Future->wrap($engine->export_otlp_f($records,
        endpoint     => $endpoint,
        service_name => $class,
      ))
    );
  };
  if ($@) { fail "export_otlp_f: $@"; return; }
  ok($response->is_success, "OTLP export to $endpoint returned 2xx");
  diag "OTLP export status: " . $response->status_line;
};

done_testing;
