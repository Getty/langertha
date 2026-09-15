#!/usr/bin/env perl
# ABSTRACT: Defensive deref guards for content-less / data-less 200 payloads (karr k171)
use strict;
use warnings;
use Test2::Bundle::More;
use JSON::MaybeXS;
use HTTP::Response;

use Langertha::Engine::Anthropic;
use Langertha::Engine::vLLM;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

sub mock_http {
  my ($body) = @_;
  my $http = HTTP::Response->new(200, 'OK');
  $http->content($json->encode($body));
  $http->header('Content-Type' => 'application/json');
  return $http;
}

# --- AnthropicCompatible::chat_response content-deref guard (k171) ------------
# A shim can answer a 200 whose JSON body lacks the `content` array (an error
# shape squeezed through the /anthropic shim). @{$data->{content}} used to crash
# on @{undef}; the // [] guard yields graceful empty content instead.
my $anthropic = Langertha::Engine::Anthropic->new(
  api_key => 'test',
  model   => 'claude-3-5-sonnet-20240620',
);

# Sanity: a well-formed body still parses.
{
  my $resp = $anthropic->chat_response(mock_http({
    id      => 'msg_1',
    model   => 'claude-3-5-sonnet-20240620',
    content => [ { type => 'text', text => 'hello' } ],
    stop_reason => 'end_turn',
  }));
  is("$resp", 'hello', 'Anthropic: well-formed content still parsed');
}

# A content-less 200 (error shape) must not crash -- graceful empty content.
{
  my $resp = eval {
    $anthropic->chat_response(mock_http({
      type  => 'error',
      error => { type => 'invalid_request_error', message => 'bad' },
    }));
  };
  ok(!$@, 'Anthropic: content-less 200 does not crash on @{undef}') or diag($@);
  ok($resp, 'Anthropic: content-less 200 returns a Response');
  is("$resp", '', 'Anthropic: content-less 200 yields empty content');
}

# --- OpenAICompatible::embedding_response data-deref guard (k171) -------------
# A malformed/error payload that still parses as 200 JSON can lack the `data`
# array. @{$data->{data}} crashed with "Can't use an undefined value as an ARRAY
# reference"; the guard croaks with a readable message instead.
my $vllm = Langertha::Engine::vLLM->new( url => 'http://x' );

# Sanity: a well-formed embedding body still returns its vector.
{
  my $vec = $vllm->embedding_response(mock_http({
    object => 'list',
    data   => [ { object => 'embedding', index => 0, embedding => [ 0.1, 0.2, 0.3 ] } ],
  }));
  is_deeply($vec, [ 0.1, 0.2, 0.3 ], 'embedding: well-formed data still returns vector');
}

# A data-less error shape croaks with a speaking message, not a raw deref crash.
{
  my $vec = eval {
    $vllm->embedding_response(mock_http({
      error => { type => 'invalid_request_error', message => 'no input given' },
    }));
  };
  my $err = $@;
  ok(!defined $vec, 'embedding: data-less 200 does not return a value');
  like($err, qr/missing 'data' array/, 'embedding: croaks with a speaking message');
  like($err, qr/no input given/, 'embedding: croak surfaces the payload error message');
  unlike($err, qr/undefined value as an ARRAY reference/,
    'embedding: no raw deref crash');
}

# A non-array `data` (e.g. a string) also croaks rather than deref-crashing.
{
  my $vec = eval {
    $vllm->embedding_response(mock_http({ data => 'oops' }));
  };
  ok(!defined $vec, 'embedding: non-array data does not return a value');
  like($@, qr/missing 'data' array/, 'embedding: non-array data croaks cleanly');
}

done_testing;
