#!/usr/bin/env perl
# ABSTRACT: Offline tests for Langertha::Runtime::Metrics Prometheus parser

use strict;
use warnings;

use Test2::Bundle::More;

use Langertha::Runtime::Metrics;

my $metrics = Langertha::Runtime::Metrics->new;

# --- vLLM-style payload ---
{
  my $payload = <<'EOF';
# HELP vllm:num_requests_running Number of running requests
# TYPE vllm:num_requests_running gauge
vllm:num_requests_running{model_name="Qwen/Qwen2.5-7B-Instruct"} 3
# HELP vllm:prompt_tokens_total Prompt tokens processed
# TYPE vllm:prompt_tokens_total counter
vllm:prompt_tokens_total{model_name="Qwen/Qwen2.5-7B-Instruct"} 18234
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total{endpoint="v1.chat.completions",method="POST",status="200"} 412
EOF

  my $records = $metrics->parse($payload);
  ok(ref($records) eq 'ARRAY', 'parse() returns ArrayRef');

  # Find records by name to avoid order-coupling
  my %by_name = map { $_->{name} => $_ } @$records;
  ok(exists $by_name{'vllm:num_requests_running'}, 'vllm:num_requests_running record present');
  is($by_name{'vllm:num_requests_running'}{type}, 'gauge', 'gauge type attached from # TYPE directive');
  is($by_name{'vllm:num_requests_running'}{value}, 3, 'numeric value coerced');
  is_deeply($by_name{'vllm:num_requests_running'}{labels},
    { model_name => 'Qwen/Qwen2.5-7B-Instruct' },
    'labels parsed for gauge');

  is($by_name{'vllm:prompt_tokens_total'}{type}, 'counter', 'counter type attached');
  is($by_name{'vllm:prompt_tokens_total'}{value}, 18234, 'counter value');

  is($by_name{'http_requests_total'}{type}, 'counter', 'http counter type attached');
  is_deeply($by_name{'http_requests_total'}{labels},
    { endpoint => 'v1.chat.completions', method => 'POST', status => '200' },
    'multi-label parsed');

  # Filter to vllm:
  my $vllm_only = $metrics->filter_prefix($records, 'vllm:');
  is(scalar @$vllm_only, 2, 'filter_prefix keeps two vllm records');
  ok(!(scalar grep { $_->{name} =~ /^http:/ } @$vllm_only), 'http records excluded from vllm filter');
}

# --- SGLang-style payload ---
{
  my $payload = <<'EOF';
# HELP sglang:num_running_reqs Number of running requests
# TYPE sglang:num_running_reqs gauge
sglang:num_running_reqs{model="Qwen/Qwen2.5-7B-Instruct"} 2
# HELP sglang:prompt_tokens_total Prompt tokens processed
# TYPE sglang:prompt_tokens_total counter
sglang:prompt_tokens_total{model="Qwen/Qwen2.5-7B-Instruct"} 9431
# HELP sglang:gen_throughput Generation throughput (tokens/s)
# TYPE sglang:gen_throughput gauge
sglang:gen_throughput{model="Qwen/Qwen2.5-7B-Instruct"} 18.4
EOF

  my $records = $metrics->parse_and_filter($payload, 'sglang:');
  is(scalar @$records, 3, 'parse_and_filter returns all three sglang records');
  my %by_name = map { $_->{name} => $_ } @$records;
  is($by_name{'sglang:num_running_reqs'}{value}, 2, 'sglang gauge value');
  is($by_name{'sglang:prompt_tokens_total'}{type}, 'counter', 'sglang counter type');
  is($by_name{'sglang:gen_throughput'}{value} + 0, 18.4, 'sglang float value coerced');
}

# --- llama.cpp-style payload (histogram inheritance) ---
{
  my $payload = <<'EOF';
# HELP llama_prompt_tokens_total Total prompt tokens processed
# TYPE llama_prompt_tokens_total counter
llama_prompt_tokens_total 12450
# HELP llama_tokens_predicted_total Total generated tokens
# TYPE llama_tokens_predicted_total counter
llama_tokens_predicted_total 8213
# HELP llama_requests_processing Number of in-flight requests
# TYPE llama_requests_processing gauge
llama_requests_processing 1
# HELP llama_request_duration_seconds Request duration histogram
# TYPE llama_request_duration_seconds histogram
llama_request_duration_seconds_bucket{le="0.5"} 47
llama_request_duration_seconds_bucket{le="1.0"} 51
llama_request_duration_seconds_bucket{le="+Inf"} 52
llama_request_duration_seconds_sum 23.4
llama_request_duration_seconds_count 52
EOF

  my $records = $metrics->parse_and_filter($payload, 'llama_');
  is(scalar @$records, 8, 'parse_and_filter returns all llama records (3 + 5 histogram series)');
  my %by_name = map { $_->{name} => $_ } @$records;

  is($by_name{'llama_prompt_tokens_total'}{type}, 'counter', 'counter type');
  is($by_name{'llama_tokens_predicted_total'}{type}, 'counter', 'counter type #2');
  is($by_name{'llama_requests_processing'}{type}, 'gauge', 'gauge type');

  # Histogram base name inherits to bucket/sum/count
  is($by_name{'llama_request_duration_seconds_bucket'}{type}, 'histogram',
    'histogram type inherited by _bucket series');
  is($by_name{'llama_request_duration_seconds_sum'}{type}, 'histogram',
    'histogram type inherited by _sum series');
  is($by_name{'llama_request_duration_seconds_count'}{type}, 'histogram',
    'histogram type inherited by _count series');
  is_deeply($by_name{'llama_request_duration_seconds_bucket'}{labels},
    { le => '+Inf' },
    'le=+Inf label preserved');

  # Multiple-prefix OR filter
  my $both = $metrics->parse_and_filter($payload, 'llama_prompt', 'llama_tokens');
  is(scalar @$both, 2, 'multi-prefix OR filter returns two records');
}

# --- Malformed input is skipped, not fatal ---
{
  my $payload = <<'EOF';
# HELP vllm:ok good
# TYPE vllm:ok gauge
vllm:ok{model="q"} 1
this is not a valid metric line at all
vllm:another{model="q"} 2
EOF

  my $records;
  my $ok = eval { $records = $metrics->parse($payload); 1 };
  ok($ok, 'malformed payload does not croak');
  is(scalar @$records, 2, 'only well-formed lines returned');
  my %by_name = map { $_->{name} => $_ } @$records;
  is($by_name{'vllm:ok'}{value}, 1, 'first valid record kept');
  is($by_name{'vllm:another'}{value}, 2, 'second valid record kept');
}

# --- Empty / blank input ---
{
  my $records = $metrics->parse('');
  is_deeply($records, [], 'empty payload returns empty arrayref');

  my $comments_only = $metrics->parse("# HELP foo\n# TYPE foo gauge\n");
  is_deeply($comments_only, [], 'comment-only payload returns empty arrayref');
}

# --- Argument validation ---
{
  my $records = $metrics->parse('vllm:ok 1');
  is(scalar @{$metrics->filter_prefix($records, 'vllm:')}, 1, 'filter_prefix on parsed records');

  eval { $metrics->filter_prefix([], 'vllm:'); 1 };
  ok(!$@, 'filter_prefix accepts ArrayRef');

  eval { $metrics->filter_prefix($records); 1 };
  ok($@, 'filter_prefix croaks without a prefix');

  eval { $metrics->parse(undef); 1 };
  ok($@, 'parse croaks on undef');
}

done_testing;
