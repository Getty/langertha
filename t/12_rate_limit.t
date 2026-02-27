#!/usr/bin/env perl
# ABSTRACT: Test rate limit extraction from HTTP response headers

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;
use HTTP::Response;

use Langertha::RateLimit;
use Langertha::Response;
use Langertha::Engine::OpenAI;
use Langertha::Engine::Anthropic;
use Langertha::Engine::vLLM;
use Langertha::Engine::Ollama;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

# ======================================================================
# Part 1: RateLimit data class
# ======================================================================

{
  my $rl = Langertha::RateLimit->new(
    requests_limit     => 100,
    requests_remaining => 95,
    requests_reset     => '5s',
    tokens_limit       => 40000,
    tokens_remaining   => 39500,
    tokens_reset       => '10s',
    raw                => { 'x-ratelimit-limit-requests' => '100' },
  );
  is($rl->requests_limit, 100, 'RateLimit requests_limit');
  is($rl->requests_remaining, 95, 'RateLimit requests_remaining');
  is($rl->requests_reset, '5s', 'RateLimit requests_reset');
  is($rl->tokens_limit, 40000, 'RateLimit tokens_limit');
  is($rl->tokens_remaining, 39500, 'RateLimit tokens_remaining');
  is($rl->tokens_reset, '10s', 'RateLimit tokens_reset');
  is(ref $rl->raw, 'HASH', 'RateLimit raw is HashRef');

  my $hash = $rl->to_hash;
  is($hash->{requests_limit}, 100, 'to_hash requests_limit');
  is($hash->{tokens_remaining}, 39500, 'to_hash tokens_remaining');
  ok(exists $hash->{raw}, 'to_hash includes raw');
}

# RateLimit with no values
{
  my $rl = Langertha::RateLimit->new;
  is($rl->requests_limit, undef, 'empty RateLimit requests_limit is undef');
  is($rl->tokens_remaining, undef, 'empty RateLimit tokens_remaining is undef');
  my $hash = $rl->to_hash;
  ok(!exists $hash->{requests_limit}, 'to_hash omits undef fields');
  ok(exists $hash->{raw}, 'to_hash always includes raw');
}

# ======================================================================
# Part 2: OpenAI-style x-ratelimit-* header parsing
# ======================================================================

{
  my $openai = Langertha::Engine::OpenAI->new(
    api_key => 'testkey',
    model   => 'gpt-4o-mini',
  );

  my $http = HTTP::Response->new(200, 'OK');
  $http->content($json->encode({
    id      => 'chatcmpl-test',
    model   => 'gpt-4o-mini',
    choices => [{ message => { role => 'assistant', content => 'Hello' }, finish_reason => 'stop' }],
    usage   => { prompt_tokens => 5, completion_tokens => 1, total_tokens => 6 },
  }));
  $http->header('Content-Type' => 'application/json');
  $http->header('x-ratelimit-limit-requests' => '500');
  $http->header('x-ratelimit-remaining-requests' => '499');
  $http->header('x-ratelimit-reset-requests' => '12s');
  $http->header('x-ratelimit-limit-tokens' => '30000');
  $http->header('x-ratelimit-remaining-tokens' => '29990');
  $http->header('x-ratelimit-reset-tokens' => '6s');

  my $resp = $openai->chat_response($http);
  isa_ok($resp, 'Langertha::Response');

  # Engine should have rate limit stored
  ok($openai->has_rate_limit, 'OpenAI engine has_rate_limit after response');
  my $rl = $openai->rate_limit;
  isa_ok($rl, 'Langertha::RateLimit');
  is($rl->requests_limit, 500, 'OpenAI requests_limit parsed');
  is($rl->requests_remaining, 499, 'OpenAI requests_remaining parsed');
  is($rl->requests_reset, '12s', 'OpenAI requests_reset parsed');
  is($rl->tokens_limit, 30000, 'OpenAI tokens_limit parsed');
  is($rl->tokens_remaining, 29990, 'OpenAI tokens_remaining parsed');
  is($rl->tokens_reset, '6s', 'OpenAI tokens_reset parsed');
  is($rl->raw->{'x-ratelimit-limit-requests'}, '500', 'OpenAI raw headers preserved');
}

# ======================================================================
# Part 3: Anthropic anthropic-ratelimit-* header parsing
# ======================================================================

{
  my $anthropic = Langertha::Engine::Anthropic->new(
    api_key => 'testkey',
    model   => 'claude-sonnet-4-6',
  );

  my $http = HTTP::Response->new(200, 'OK');
  $http->content($json->encode({
    id          => 'msg_test',
    model       => 'claude-sonnet-4-6',
    stop_reason => 'end_turn',
    content     => [{ type => 'text', text => 'Hello' }],
    usage       => { input_tokens => 5, output_tokens => 1 },
  }));
  $http->header('Content-Type' => 'application/json');
  $http->header('anthropic-ratelimit-requests-limit' => '1000');
  $http->header('anthropic-ratelimit-requests-remaining' => '999');
  $http->header('anthropic-ratelimit-requests-reset' => '2026-02-27T12:00:00Z');
  $http->header('anthropic-ratelimit-tokens-limit' => '80000');
  $http->header('anthropic-ratelimit-tokens-remaining' => '79500');
  $http->header('anthropic-ratelimit-tokens-reset' => '2026-02-27T12:00:00Z');
  $http->header('anthropic-ratelimit-input-tokens-limit' => '50000');
  $http->header('anthropic-ratelimit-output-tokens-limit' => '30000');

  my $resp = $anthropic->chat_response($http);
  isa_ok($resp, 'Langertha::Response');

  ok($anthropic->has_rate_limit, 'Anthropic engine has_rate_limit');
  my $rl = $anthropic->rate_limit;
  isa_ok($rl, 'Langertha::RateLimit');
  is($rl->requests_limit, 1000, 'Anthropic requests_limit parsed');
  is($rl->requests_remaining, 999, 'Anthropic requests_remaining parsed');
  is($rl->requests_reset, '2026-02-27T12:00:00Z', 'Anthropic requests_reset parsed');
  is($rl->tokens_limit, 80000, 'Anthropic tokens_limit parsed');
  is($rl->tokens_remaining, 79500, 'Anthropic tokens_remaining parsed');
  # Check raw includes provider-specific extras
  is($rl->raw->{'anthropic-ratelimit-input-tokens-limit'}, '50000', 'Anthropic raw includes input-tokens-limit');
  is($rl->raw->{'anthropic-ratelimit-output-tokens-limit'}, '30000', 'Anthropic raw includes output-tokens-limit');
}

# ======================================================================
# Part 4: No headers => no rate_limit (local engines)
# ======================================================================

{
  my $ollama = Langertha::Engine::Ollama->new(
    url   => 'http://test.invalid:11434',
    model => 'llama3.3',
  );

  my $http = HTTP::Response->new(200, 'OK');
  $http->content($json->encode({
    model   => 'llama3.3:latest',
    message => { role => 'assistant', content => 'Hello' },
    done    => JSON->true,
    done_reason => 'stop',
  }));
  $http->header('Content-Type' => 'application/json');

  $ollama->chat_response($http);
  ok(!$ollama->has_rate_limit, 'Ollama has no rate_limit (no headers)');
}

# ======================================================================
# Part 5: Rate limit attached to Response via simple_chat flow
# ======================================================================

{
  my $openai = Langertha::Engine::OpenAI->new(
    api_key => 'testkey',
    model   => 'gpt-4o-mini',
  );

  # First, set rate limit via parse_response (simulating a prior request)
  my $http = HTTP::Response->new(200, 'OK');
  $http->content($json->encode({
    id      => 'chatcmpl-test2',
    model   => 'gpt-4o-mini',
    choices => [{ message => { role => 'assistant', content => 'Hi' }, finish_reason => 'stop' }],
    usage   => { prompt_tokens => 5, completion_tokens => 1, total_tokens => 6 },
  }));
  $http->header('Content-Type' => 'application/json');
  $http->header('x-ratelimit-limit-requests' => '200');
  $http->header('x-ratelimit-remaining-requests' => '198');
  $http->header('x-ratelimit-limit-tokens' => '50000');
  $http->header('x-ratelimit-remaining-tokens' => '49000');

  # Simulate what simple_chat does: parse_response + clone_with
  my $resp = $openai->chat_response($http);
  ok($openai->has_rate_limit, 'engine has rate_limit before clone');

  my $cloned = $resp->clone_with(rate_limit => $openai->rate_limit);
  ok($cloned->has_rate_limit, 'cloned Response has rate_limit');
  is($cloned->requests_remaining, 198, 'Response requests_remaining via delegation');
  is($cloned->tokens_remaining, 49000, 'Response tokens_remaining via delegation');
  is("$cloned", 'Hi', 'cloned Response still stringifies correctly');
  is($cloned->id, 'chatcmpl-test2', 'cloned Response preserves id');
}

# ======================================================================
# Part 6: Engine stores latest rate_limit (updates on each response)
# ======================================================================

{
  my $openai = Langertha::Engine::OpenAI->new(
    api_key => 'testkey',
    model   => 'gpt-4o-mini',
  );

  ok(!$openai->has_rate_limit, 'fresh engine has no rate_limit');

  # First response
  my $http1 = HTTP::Response->new(200, 'OK');
  $http1->content($json->encode({
    id => 'r1', model => 'gpt-4o-mini',
    choices => [{ message => { content => 'A' }, finish_reason => 'stop' }],
  }));
  $http1->header('Content-Type' => 'application/json');
  $http1->header('x-ratelimit-remaining-requests' => '100');
  $openai->chat_response($http1);
  is($openai->rate_limit->requests_remaining, 100, 'first response: 100 remaining');

  # Second response
  my $http2 = HTTP::Response->new(200, 'OK');
  $http2->content($json->encode({
    id => 'r2', model => 'gpt-4o-mini',
    choices => [{ message => { content => 'B' }, finish_reason => 'stop' }],
  }));
  $http2->header('Content-Type' => 'application/json');
  $http2->header('x-ratelimit-remaining-requests' => '99');
  $openai->chat_response($http2);
  is($openai->rate_limit->requests_remaining, 99, 'second response: 99 remaining (updated)');
}

# ======================================================================
# Part 7: vLLM with custom rate limit headers
# ======================================================================

{
  my $vllm = Langertha::Engine::vLLM->new(
    url => 'http://test.invalid:8000/v1',
  );

  my $http = HTTP::Response->new(200, 'OK');
  $http->content($json->encode({
    id      => 'vllm-test',
    model   => 'default',
    choices => [{ message => { content => 'Hi' }, finish_reason => 'stop' }],
  }));
  $http->header('Content-Type' => 'application/json');
  # vLLM behind a proxy might add rate limit headers
  $http->header('x-ratelimit-limit-requests' => '60');
  $http->header('x-ratelimit-remaining-requests' => '58');

  $vllm->chat_response($http);
  ok($vllm->has_rate_limit, 'vLLM with proxy rate limit headers');
  is($vllm->rate_limit->requests_limit, 60, 'vLLM requests_limit');
  is($vllm->rate_limit->requests_remaining, 58, 'vLLM requests_remaining');
  is($vllm->rate_limit->tokens_limit, undef, 'vLLM tokens_limit undef (not set)');
}

# No rate limit headers on vLLM
{
  my $vllm = Langertha::Engine::vLLM->new(
    url => 'http://test.invalid:8000/v1',
  );

  my $http = HTTP::Response->new(200, 'OK');
  $http->content($json->encode({
    id      => 'vllm-test2',
    model   => 'default',
    choices => [{ message => { content => 'Hi' }, finish_reason => 'stop' }],
  }));
  $http->header('Content-Type' => 'application/json');

  $vllm->chat_response($http);
  ok(!$vllm->has_rate_limit, 'vLLM without rate limit headers has no rate_limit');
}

# ======================================================================
# Part 8: Response without rate_limit (delegation returns undef)
# ======================================================================

{
  my $resp = Langertha::Response->new(content => 'plain response');
  ok(!$resp->has_rate_limit, 'plain Response has no rate_limit');
  is($resp->requests_remaining, undef, 'requests_remaining undef without rate_limit');
  is($resp->tokens_remaining, undef, 'tokens_remaining undef without rate_limit');
}

done_testing;
