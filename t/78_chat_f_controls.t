#!/usr/bin/env perl
# ABSTRACT: Canonical per-request controls (karr #46) land on the right wire per engine family

# karr #46: chat_f normalized only messages/tools/tool_choice; everything else
# was spread as raw target-wire kwargs, so the same call was correct,
# ineffective, or a 400 depending on engine family (temperature/max_tokens on
# Ollama silently lost under options, response_format a 400 on Anthropic, seed
# only honored where the engine happened to advertise it). chat_f now extracts
# a canonical control set (temperature, max_tokens, response_format, seed,
# parallel_tool_use, reasoning_effort, thinking_budget, prompt_cache,
# prompt_cache_ttl, prompt_cache_key) into a `controls` hash that each engine's
# chat_request consumes and places via the same value objects the engine
# attributes use. Unknown keys still pass straight through.

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;
use HTTP::Response;

use lib 't/lib';
use Test::MockAsyncHTTP;

use Langertha::Engine::OpenAI;
use Langertha::Engine::Anthropic;
use Langertha::Engine::Ollama;
use Langertha::Engine::Gemini;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

my $SCHEMA = {
  type       => 'object',
  properties => { city => { type => 'string' } },
  required   => ['city'],
};

sub openai {
  return Langertha::Engine::OpenAI->new(
    api_key => 'apikey',
    model   => 'gpt-4o-mini',
    @_,
  );
}

sub anthropic {
  return Langertha::Engine::Anthropic->new(
    api_key       => 'apikey',
    model         => 'claude-x',
    response_size => 256,
    @_,
  );
}

sub ollama {
  return Langertha::Engine::Ollama->new(
    url   => 'http://test.url:12345',
    model => 'model',
    @_,
  );
}

sub gemini {
  return Langertha::Engine::Gemini->new(
    api_key => 'apikey',
    model   => 'gemini-3-flash-preview',
    @_,
  );
}

# Simulate what chat_f does: canonical controls arrive under `controls`.
sub wire {
  my ( $engine, %extra ) = @_;
  return $json->decode(
    $engine->chat_request( $engine->chat_messages('testprompt'), %extra )->content
  );
}

# --- _extract_controls: canonical keys out, unknown keys stay -------------
{
  my $engine = openai();
  my %opts = (
    temperature      => 0.3,
    max_tokens       => 100,
    response_format  => { type => 'json_object' },
    seed             => 42,
    parallel_tool_use => 0,
    reasoning_effort => 'high',
    thinking_budget  => 1000,
    prompt_cache     => 1,
    prompt_cache_ttl => 300,
    prompt_cache_key => 'k',
    custom_extra     => 'still-here',
  );
  my $controls = $engine->_extract_controls(\%opts);

  is_deeply( $controls, {
    temperature       => 0.3,
    max_tokens        => 100,
    response_format   => { type => 'json_object' },
    seed              => 42,
    parallel_tool_use => 0,
    reasoning_effort  => 'high',
    thinking_budget   => 1000,
    prompt_cache      => 1,
    prompt_cache_ttl  => 300,
    prompt_cache_key  => 'k',
  }, '_extract_controls pulls every canonical control out of %opts' );
  is_deeply( \%opts, { custom_extra => 'still-here' },
    '_extract_controls leaves unknown keys in %opts' );
}

# --- OpenAI-compatible: controls land top-level ---------------------------
{
  my $data = wire( openai(), controls => {
    temperature      => 0.3,
    max_tokens       => 100,
    seed             => 42,
    reasoning_effort => 'high',
    response_format  => { type => 'json_object' },
  });

  is( $data->{temperature}, 0.3, 'OpenAI: temperature control lands top-level' );
  is( $data->{max_tokens}, 100, 'OpenAI: max_tokens control lands top-level' );
  is( $data->{seed}, 42, 'OpenAI: seed control lands top-level' );
  is( $data->{reasoning_effort}, 'high',
    'OpenAI: reasoning_effort control lands top-level via Langertha::Reasoning' );
  is_deeply( $data->{response_format}, { type => 'json_object' },
    'OpenAI: response_format control lands top-level' );
  ok( !exists $data->{controls}, 'OpenAI: controls hash is consumed, not leaked' );
}

# --- OpenAI-compatible: parallel_tool_use -> parallel_tool_calls ----------
{
  my $data = wire( openai(), controls => { parallel_tool_use => 0 },
    tools => [ { type => 'function', function => { name => 'f', parameters => { type => 'object' } } } ] );

  is( $data->{parallel_tool_calls}, JSON->false,
    'OpenAI: parallel_tool_use=0 control becomes parallel_tool_calls=false' );

  my $on = wire( openai(), controls => { parallel_tool_use => 1 },
    tools => [ { type => 'function', function => { name => 'f', parameters => { type => 'object' } } } ] );
  is( $on->{parallel_tool_calls}, JSON->true,
    'OpenAI: parallel_tool_use=1 control becomes parallel_tool_calls=true' );
}

# --- OpenAI-compatible: per-request control beats engine attribute --------
{
  my $engine = openai( temperature => 0.9, response_size => 500 );
  my $data = wire( $engine, controls => { temperature => 0.1, max_tokens => 77 } );

  is( $data->{temperature}, 0.1, 'OpenAI: per-request temperature beats the attribute' );
  is( $data->{max_tokens}, 77, 'OpenAI: per-request max_tokens beats response_size' );
}

# --- OpenAI-compatible: unknown keys still pass through --------------------
{
  my $data = wire( openai(), controls => { temperature => 0.3 }, custom_extra => 'x' );
  is( $data->{custom_extra}, 'x', 'OpenAI: unknown key still passes straight through' );
}

# --- Anthropic: controls land on the Messages wire ------------------------
{
  my $data = wire( anthropic(), controls => {
    temperature      => 0.3,
    max_tokens       => 100,
    reasoning_effort => 'high',
  });

  is( $data->{temperature}, 0.3, 'Anthropic: temperature control lands top-level' );
  is( $data->{max_tokens}, 100, 'Anthropic: max_tokens control lands top-level' );
  is_deeply( $data->{output_config}, { effort => 'high' },
    'Anthropic: reasoning_effort control lands as output_config.effort' );
  is_deeply( $data->{thinking}, { type => 'adaptive' },
    'Anthropic: reasoning_effort control lands as thinking:{type:adaptive}' );
  ok( !exists $data->{controls}, 'Anthropic: controls hash is consumed, not leaked' );
}

# --- Anthropic: parallel_tool_use -> tool_choice.disable_parallel_tool_use
{
  my $data = wire( anthropic(), controls => { parallel_tool_use => 1 },
    tools => [ { name => 'f', input_schema => { type => 'object' } } ] );

  is( $data->{tool_choice}{disable_parallel_tool_use}, JSON->false,
    'Anthropic: parallel_tool_use=1 control -> disable_parallel_tool_use=false' );

  my $off = wire( anthropic(), controls => { parallel_tool_use => 0 },
    tools => [ { name => 'f', input_schema => { type => 'object' } } ] );
  is( $off->{tool_choice}{disable_parallel_tool_use}, JSON->true,
    'Anthropic: parallel_tool_use=0 control -> disable_parallel_tool_use=true' );
}

# --- Anthropic: response_format control routes through the synth tool -----
{
  my $data = wire( anthropic(), controls => {
    response_format => {
      type        => 'json_schema',
      json_schema => { name => 'extract', schema => $SCHEMA },
    },
  });

  ok( !exists $data->{response_format},
    'Anthropic: response_format control is consumed, not passed to the wire' );
  is( $data->{tool_choice}{name}, 'extract',
    'Anthropic: response_format control forces the synthesized tool' );
  is_deeply( $data->{tools}[0]{input_schema}, $SCHEMA,
    'Anthropic: response_format control schema reaches the synthesized tool' );
}

# --- Anthropic: unknown keys still pass through ----------------------------
{
  my $data = wire( anthropic(), controls => { temperature => 0.3 }, custom_extra => 'x' );
  is( $data->{custom_extra}, 'x', 'Anthropic: unknown key still passes straight through' );
}

# --- Ollama: controls land under options, not top-level -------------------
{
  my $data = wire( ollama(), controls => {
    temperature      => 0.3,
    max_tokens       => 100,
    seed             => 42,
    reasoning_effort => 'high',
  });

  is( $data->{options}{temperature}, 0.3,
    'Ollama: temperature control lands under options (not top-level)' );
  ok( !exists $data->{temperature}, 'Ollama: no top-level temperature leak' );
  is( $data->{options}{num_predict}, 100,
    'Ollama: max_tokens control lands as options.num_predict (not top-level)' );
  ok( !exists $data->{max_tokens}, 'Ollama: no top-level max_tokens leak' );
  is( $data->{options}{seed}, 42, 'Ollama: seed control lands under options' );
  is( $data->{options}{think}, JSON->true,
    'Ollama: reasoning_effort control lands as options.think' );
  ok( !exists $data->{controls}, 'Ollama: controls hash is consumed, not leaked' );
}

# --- Ollama: reasoning_effort=none turns think off ------------------------
{
  my $data = wire( ollama(), controls => { reasoning_effort => 'none' } );
  is( $data->{options}{think}, JSON->false,
    'Ollama: reasoning_effort=none control -> options.think=false' );
}

# --- Ollama: response_format control -> format ----------------------------
{
  my $data = wire( ollama(), controls => {
    response_format => {
      type        => 'json_schema',
      json_schema => { name => 'extract', schema => $SCHEMA },
    },
  });

  ok( !exists $data->{response_format},
    'Ollama: response_format control is consumed, not passed to the wire' );
  is_deeply( $data->{format}, $SCHEMA,
    'Ollama: response_format control becomes the format schema' );
}

# --- Ollama: per-request control beats engine attribute -------------------
{
  my $engine = ollama( temperature => 0.9, response_size => 500 );
  my $data = wire( $engine, controls => { temperature => 0.1, max_tokens => 77 } );

  is( $data->{options}{temperature}, 0.1,
    'Ollama: per-request temperature beats the attribute' );
  is( $data->{options}{num_predict}, 77,
    'Ollama: per-request max_tokens beats response_size' );
}

# --- Ollama: unknown keys still pass through -------------------------------
{
  my $data = wire( ollama(), controls => { temperature => 0.3 }, custom_extra => 'x' );
  is( $data->{custom_extra}, 'x', 'Ollama: unknown key still passes straight through' );
}

# --- Gemini: controls land under generationConfig -------------------------
{
  my $data = wire( gemini(), controls => {
    temperature      => 0.3,
    max_tokens       => 100,
    reasoning_effort => 'high',
  });

  is( $data->{generationConfig}{temperature}, 0.3,
    'Gemini: temperature control lands under generationConfig' );
  is( $data->{generationConfig}{maxOutputTokens}, 100,
    'Gemini: max_tokens control lands as generationConfig.maxOutputTokens' );
  is_deeply( $data->{generationConfig}{thinkingConfig}, { thinkingLevel => 'high' },
    'Gemini: reasoning_effort control lands as thinkingConfig.thinkingLevel' );
  ok( !exists $data->{controls}, 'Gemini: controls hash is consumed, not leaked' );
}

# --- Gemini: response_format control -> generationConfig.responseSchema ----
{
  my $data = wire( gemini(), controls => {
    response_format => {
      type        => 'json_schema',
      json_schema => { name => 'extract', schema => $SCHEMA },
    },
  });

  ok( !exists $data->{response_format},
    'Gemini: response_format control is consumed, not passed to the wire' );
  is_deeply( $data->{generationConfig}{responseSchema}, $SCHEMA,
    'Gemini: response_format control becomes generationConfig.responseSchema' );
}

# --- Gemini: unknown keys still pass through -------------------------------
{
  my $data = wire( gemini(), controls => { temperature => 0.3 }, custom_extra => 'x' );
  is( $data->{custom_extra}, 'x', 'Gemini: unknown key still passes straight through' );
}

# --- End-to-end: chat_f extracts controls and they reach the wire ----------
# Ollama is the discriminating engine: temperature/max_tokens/seed spread as
# raw extras would land top-level (silently ignored by the API), so this test
# only passes when chat_f routes them through the controls channel into
# options.
{
  my $mock = Test::MockAsyncHTTP->new( responses => [
    Test::MockAsyncHTTP->mock_json_response({
      model       => 'model',
      message     => { role => 'assistant', content => 'hello' },
      done_reason => 'stop',
      done        => JSON->true,
    }),
  ]);

  my $engine = ollama( _async_http => $mock );

  my $future = $engine->chat_f(
    messages         => ['hi'],
    temperature      => 0.3,
    max_tokens       => 100,
    seed             => 42,
    reasoning_effort => 'high',
    custom_extra     => 'x',
  );
  my $response = $future->get;

  is( $response->content, 'hello', 'chat_f returns the response' );
  is( $mock->request_count, 1, 'chat_f made exactly one request' );

  my ($request) = $mock->requests;
  my $body = $json->decode( $request->content );
  is( $body->{options}{temperature}, 0.3,
    'chat_f: temperature control reached options.temperature' );
  is( $body->{options}{num_predict}, 100,
    'chat_f: max_tokens control reached options.num_predict' );
  is( $body->{options}{seed}, 42, 'chat_f: seed control reached options.seed' );
  is( $body->{options}{think}, JSON->true,
    'chat_f: reasoning_effort control reached options.think' );
  ok( !exists $body->{temperature} && !exists $body->{max_tokens}
    && !exists $body->{seed} && !exists $body->{reasoning_effort},
    'chat_f: no canonical control leaked top-level (raw-extra path not used)' );
  is( $body->{custom_extra}, 'x', 'chat_f: unknown key still passes straight through' );
  ok( !exists $body->{controls}, 'chat_f: controls hash never reaches the wire' );
}

done_testing;
