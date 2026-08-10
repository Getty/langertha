#!/usr/bin/env perl
# ABSTRACT: Test Langertha::Response metadata container

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;
use HTTP::Response;

use Langertha::Response;
use Langertha::Engine::OpenAI;
use Langertha::Engine::Anthropic;
use Langertha::Engine::Gemini;
use Langertha::Engine::Ollama;
use Langertha::Engine::AKI;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

# --- Response basics ---

my $r = Langertha::Response->new(content => 'Hello world');
is("$r", 'Hello world', 'Response stringifies to content');
is($r->content, 'Hello world', 'content accessor works');
ok(!$r->has_raw, 'no raw without setting it');
ok(!$r->has_id, 'no id without setting it');
ok(!$r->has_model, 'no model without setting it');
ok(!$r->has_finish_reason, 'no finish_reason without setting it');
ok(!$r->has_usage, 'no usage without setting it');

# --- Response with all metadata ---

my $r2 = Langertha::Response->new(
  content       => 'Hi',
  raw           => { foo => 'bar' },
  id            => 'resp-123',
  model         => 'gpt-4o',
  finish_reason => 'stop',
  usage         => { prompt_tokens => 10, completion_tokens => 5, total_tokens => 15 },
  created       => 1700000000,
);
is("$r2", 'Hi', 'full Response stringifies');
is($r2->id, 'resp-123', 'id accessor');
is($r2->model, 'gpt-4o', 'model accessor');
is($r2->finish_reason, 'stop', 'finish_reason accessor');
is($r2->created, 1700000000, 'created accessor');
is($r2->prompt_tokens, 10, 'prompt_tokens convenience');
is($r2->completion_tokens, 5, 'completion_tokens convenience');
is($r2->total_tokens, 15, 'total_tokens from usage');

# --- Anthropic-style usage (input_tokens/output_tokens) ---

my $r3 = Langertha::Response->new(
  content => 'test',
  usage   => { input_tokens => 20, output_tokens => 8 },
);
is($r3->prompt_tokens, 20, 'prompt_tokens from input_tokens');
is($r3->completion_tokens, 8, 'completion_tokens from output_tokens');
is($r3->total_tokens, 28, 'total_tokens computed from sum');

# --- No usage returns undef ---

my $r4 = Langertha::Response->new(content => 'test');
is($r4->prompt_tokens, undef, 'prompt_tokens undef without usage');
is($r4->completion_tokens, undef, 'completion_tokens undef without usage');
is($r4->total_tokens, undef, 'total_tokens undef without usage');

# --- String context in expressions ---

my $r5 = Langertha::Response->new(content => 'hello');
ok($r5 eq 'hello', 'eq comparison works');
like("$r5", qr/hello/, 'regex match via stringification');

# --- OpenAI chat_response returns Response ---

my $openai = Langertha::Engine::OpenAI->new(
  api_key => 'testkey',
  model => 'gpt-4o-mini',
);

my $openai_http = HTTP::Response->new(200, 'OK');
$openai_http->content($json->encode({
  id => 'chatcmpl-abc123',
  model => 'gpt-4o-mini-2024-07-18',
  created => 1700000001,
  choices => [{
    message => { role => 'assistant', content => 'OpenAI says hello' },
    finish_reason => 'stop',
  }],
  usage => { prompt_tokens => 12, completion_tokens => 4, total_tokens => 16 },
}));
$openai_http->header('Content-Type' => 'application/json');

my $openai_resp = $openai->chat_response($openai_http);
isa_ok($openai_resp, 'Langertha::Response');
is("$openai_resp", 'OpenAI says hello', 'OpenAI Response stringifies');
is($openai_resp->id, 'chatcmpl-abc123', 'OpenAI id extracted');
is($openai_resp->model, 'gpt-4o-mini-2024-07-18', 'OpenAI model extracted');
is($openai_resp->finish_reason, 'stop', 'OpenAI finish_reason extracted');
is($openai_resp->created, 1700000001, 'OpenAI created extracted');
is($openai_resp->prompt_tokens, 12, 'OpenAI prompt_tokens');
is($openai_resp->completion_tokens, 4, 'OpenAI completion_tokens');
is($openai_resp->total_tokens, 16, 'OpenAI total_tokens');
ok($openai_resp->has_raw, 'OpenAI raw populated');

# --- Anthropic chat_response returns Response ---

my $anthropic = Langertha::Engine::Anthropic->new(
  api_key => 'testkey',
  model => 'claude-sonnet-4-6',
);

my $anthropic_http = HTTP::Response->new(200, 'OK');
$anthropic_http->content($json->encode({
  id => 'msg_abc123',
  model => 'claude-sonnet-4-6',
  stop_reason => 'end_turn',
  content => [{ type => 'text', text => 'Anthropic says hello' }],
  usage => { input_tokens => 15, output_tokens => 6 },
}));
$anthropic_http->header('Content-Type' => 'application/json');

my $anthropic_resp = $anthropic->chat_response($anthropic_http);
isa_ok($anthropic_resp, 'Langertha::Response');
is("$anthropic_resp", 'Anthropic says hello', 'Anthropic Response stringifies');
is($anthropic_resp->id, 'msg_abc123', 'Anthropic id extracted');
is($anthropic_resp->model, 'claude-sonnet-4-6', 'Anthropic model extracted');
is($anthropic_resp->finish_reason, 'end_turn', 'Anthropic finish_reason from stop_reason');
is($anthropic_resp->prompt_tokens, 15, 'Anthropic prompt_tokens from input_tokens');
is($anthropic_resp->completion_tokens, 6, 'Anthropic completion_tokens from output_tokens');
is($anthropic_resp->total_tokens, 21, 'Anthropic total_tokens computed');

# --- Gemini chat_response returns Response ---

my $gemini = Langertha::Engine::Gemini->new(
  api_key => 'testkey',
  model => 'gemini-2.5-flash',
);

my $gemini_http = HTTP::Response->new(200, 'OK');
$gemini_http->content($json->encode({
  candidates => [{
    content => { parts => [{ text => 'Gemini says hello' }], role => 'model' },
    finishReason => 'STOP',
  }],
  usageMetadata => {
    promptTokenCount => 8,
    candidatesTokenCount => 3,
    totalTokenCount => 11,
  },
  modelVersion => 'gemini-2.5-flash-preview-04-17',
}));
$gemini_http->header('Content-Type' => 'application/json');

my $gemini_resp = $gemini->chat_response($gemini_http);
isa_ok($gemini_resp, 'Langertha::Response');
is("$gemini_resp", 'Gemini says hello', 'Gemini Response stringifies');
is($gemini_resp->model, 'gemini-2.5-flash-preview-04-17', 'Gemini model from modelVersion');
is($gemini_resp->finish_reason, 'STOP', 'Gemini finish_reason extracted');
is($gemini_resp->prompt_tokens, 8, 'Gemini prompt_tokens normalized');
is($gemini_resp->completion_tokens, 3, 'Gemini completion_tokens normalized');
is($gemini_resp->total_tokens, 11, 'Gemini total_tokens normalized');

# --- Ollama chat_response returns Response ---

my $ollama = Langertha::Engine::Ollama->new(
  url => 'http://test.invalid:11434',
  model => 'llama3.3',
);

my $ollama_http = HTTP::Response->new(200, 'OK');
$ollama_http->content($json->encode({
  model => 'llama3.3:latest',
  message => { role => 'assistant', content => 'Ollama says hello' },
  done => JSON->true,
  done_reason => 'stop',
  total_duration => 5000000000,
  load_duration => 1000000000,
  prompt_eval_count => 20,
  prompt_eval_duration => 200000000,
  eval_count => 10,
  eval_duration => 300000000,
}));
$ollama_http->header('Content-Type' => 'application/json');

my $ollama_resp = $ollama->chat_response($ollama_http);
isa_ok($ollama_resp, 'Langertha::Response');
is("$ollama_resp", 'Ollama says hello', 'Ollama Response stringifies');
is($ollama_resp->model, 'llama3.3:latest', 'Ollama model extracted');
is($ollama_resp->finish_reason, 'stop', 'Ollama finish_reason from done_reason');
is($ollama_resp->prompt_tokens, 20, 'Ollama prompt_tokens from prompt_eval_count');
is($ollama_resp->completion_tokens, 10, 'Ollama completion_tokens from eval_count');
ok($ollama_resp->has_timing, 'Ollama timing populated');
is($ollama_resp->timing->{total_duration}, 5000000000, 'Ollama timing total_duration');
is($ollama_resp->timing->{load_duration}, 1000000000, 'Ollama timing load_duration');
is($ollama_resp->timing->{prompt_eval_duration}, 200000000, 'Ollama timing prompt_eval_duration');
is($ollama_resp->timing->{eval_duration}, 300000000, 'Ollama timing eval_duration');
is($ollama_resp->timing->{total_seconds}, 5, 'Ollama timing total_seconds derived from ns');
is($ollama_resp->timing->{load_seconds}, 1, 'Ollama timing load_seconds derived from ns');
is($ollama_resp->timing->{prompt_eval_seconds}, 0.2, 'Ollama timing prompt_eval_seconds derived from ns');
is($ollama_resp->timing->{eval_seconds}, 0.3, 'Ollama timing eval_seconds derived from ns');
ok($ollama_resp->has_total, 'Ollama has_total from total_seconds');
is($ollama_resp->total_seconds, 5, 'Ollama total_seconds convenience');
ok(!$ollama_resp->has_ttft, 'Ollama has_ttft false (sync engine)');

# --- AKI chat_response returns Response ---

my $aki = Langertha::Engine::AKI->new(
  api_key => 'testkey',
  model => 'llama3_8b_chat',
);

my $aki_http = HTTP::Response->new(200, 'OK');
$aki_http->content($json->encode({
  success => JSON->true,
  text => 'AKI says hello',
  model_name => 'Meta-Llama-3-8B-Instruct',
  total_duration => 0.7,
}));
$aki_http->header('Content-Type' => 'application/json');

my $aki_resp = $aki->chat_response($aki_http);
isa_ok($aki_resp, 'Langertha::Response');
is("$aki_resp", 'AKI says hello', 'AKI Response stringifies');
is($aki_resp->model, 'Meta-Llama-3-8B-Instruct', 'AKI model from model_name');
ok($aki_resp->has_timing, 'AKI timing populated');
is($aki_resp->timing->{total_duration}, 0.7, 'AKI timing total_duration');

# --- clone_with: probes survives (the gap that bit karr #4) ---

subtest 'clone_with carries probes through (karr #5 regression gate)' => sub {
  my $r = Langertha::Response->new(
    content => 'x',
    probes  => { qk_cache => [ [1, 2], [3, 4] ], config => { layer => 0 } },
  );
  ok($r->has_probes, 'probes set');

  my $r2 = $r->clone_with(content => 'y');
  ok($r2->has_probes, 'probes survives a content override');
  is_deeply($r2->probes->{qk_cache}, [ [1, 2], [3, 4] ], 'probes qk_cache intact');
  is($r2->probes->{config}{layer}, 0, 'probes config intact');

  # Sequential chain: probes → rate_limit (mirrors simple_chat chain)
  require Langertha::RateLimit;
  my $rl = Langertha::RateLimit->new(
    requests_remaining => 50,
    tokens_remaining   => 2000,
    raw                => {},
  );
  my $r3 = $r2->clone_with(rate_limit => $rl);
  ok($r3->has_probes, 'probes survives a sequential rate_limit override');
  ok($r3->has_rate_limit, 'rate_limit applied');
  is_deeply($r3->probes->{qk_cache}, [ [1, 2], [3, 4] ], 'probes still intact');
  is($r3->rate_limit->requests_remaining, 50, 'rate_limit value carried');
};

# --- clone_with: raw survives ---

subtest 'clone_with carries raw through' => sub {
  my $r = Langertha::Response->new(
    content => 'hello',
    raw     => { id => 'r1', nested => { a => 1 } },
  );
  ok($r->has_raw, 'raw set');

  my $r2 = $r->clone_with(content => 'world');
  ok($r2->has_raw, 'raw survives a content override');
  is($r2->raw->{id}, 'r1', 'raw id intact');
  is($r2->raw->{nested}{a}, 1, 'raw nested hash intact');
};

# --- clone_with: timing -> tool_calls chain (karr #5 2-step regression) ---

subtest 'clone_with timing then tool_calls preserves both' => sub {
  my $r = Langertha::Response->new(content => 'orig');
  ok(!$r->has_timing, 'no timing initially');
  ok(!$r->has_tool_calls, 'no tool_calls initially');

  my $r2 = $r->clone_with(timing => { total_seconds => 1.5 });
  ok($r2->has_timing, 'timing set after first clone');
  is($r2->total_seconds, 1.5, 'total_seconds readable');
  ok(!$r2->has_tool_calls, 'no tool_calls yet');

  my $r3 = $r2->clone_with(
    tool_calls => [{
      name      => 'extract',
      arguments => { x => 1 },
      synthetic => 1,
    }],
  );
  ok($r3->has_timing, 'timing survives second clone');
  is($r3->total_seconds, 1.5, 'total_seconds survives second clone');
  ok($r3->has_tool_calls, 'tool_calls set after second clone');
  is($r3->tool_call('extract')->arguments->{x}, 1, 'tool_calls value reachable');
};

done_testing;
