#!/usr/bin/env perl
# ABSTRACT: Test Gemini engine request generation and model list

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;

use Langertha::Engine::Gemini;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

plan(44);

my $gemini = Langertha::Engine::Gemini->new(
  api_key => 'test_api_key_123',
  model => 'gemini-2.0-flash',
  system_prompt => 'You are a helpful assistant',
  response_size => 2048,
  temperature => 0.7,
);

# Test basic chat request
my $gemini_request = $gemini->chat('What is Perl?');
like($gemini_request->uri, qr{^https://generativelanguage\.googleapis\.com/v1beta/models/gemini-2\.0-flash:generateContent\?key=test_api_key_123$}, 'Gemini request URI is correct');
is($gemini_request->method, 'POST', 'Gemini request method is correct');
is($gemini_request->header('Content-Type'), 'application/json', 'Gemini request Content Type is set');

my $gemini_data = $json->decode($gemini_request->content);
is_deeply($gemini_data, {
  contents => [{
    parts => [{ text => 'What is Perl?' }],
    role => 'user',
  }],
  generationConfig => {
    maxOutputTokens => 2048,
    temperature => 0.7,
  },
  systemInstruction => {
    parts => [{ text => 'You are a helpful assistant' }],
  },
}, 'Gemini request body is correct');

# Test streaming request
my $gemini_stream_request = $gemini->chat_stream('Tell me a story');
like($gemini_stream_request->uri, qr{^https://generativelanguage\.googleapis\.com/v1beta/models/gemini-2\.0-flash:streamGenerateContent\?key=test_api_key_123&alt=sse$}, 'Gemini streaming request URI is correct');
is($gemini_stream_request->method, 'POST', 'Gemini streaming request method is correct');

my $gemini_stream_data = $json->decode($gemini_stream_request->content);
is_deeply($gemini_stream_data, {
  contents => [{
    parts => [{ text => 'Tell me a story' }],
    role => 'user',
  }],
  generationConfig => {
    maxOutputTokens => 2048,
    temperature => 0.7,
  },
  systemInstruction => {
    parts => [{ text => 'You are a helpful assistant' }],
  },
}, 'Gemini streaming request body is correct');

# Test default model
is($gemini->default_model, 'gemini-3-flash-preview', 'Gemini default model is gemini-3-flash-preview');

# --- reasoning_effort -> generationConfig.thinkingConfig.thinkingLevel (karr #16, #26) ---
ok(!exists $gemini_data->{generationConfig}{thinkingConfig},
  'Gemini omits thinkingConfig when reasoning_effort unset');

# Helper: emit a chat request for model + effort and read back the wire level.
sub _thinking_level_for {
  my ( $model, $effort ) = @_;
  my $e = Langertha::Engine::Gemini->new(
    api_key => 'k', model => $model, reasoning_effort => $effort,
  );
  my $body = $json->decode($e->chat('hi')->content);
  return $body->{generationConfig}{thinkingConfig}{thinkingLevel};
}

# Gemini 3 Flash family: full minimal|low|medium|high vocabulary
# (ai.google.dev/gemini-api/docs/thinking level table, verified 2026-08-10).
is(_thinking_level_for('gemini-3-flash-preview', 'high'),    'high',    'gemini-3-flash-preview: high -> high');
is(_thinking_level_for('gemini-3-flash-preview', 'low'),     'low',     'gemini-3-flash-preview: low -> low');
is(_thinking_level_for('gemini-3-flash-preview', 'medium'),  'medium',  'gemini-3-flash-preview: medium -> medium');
is(_thinking_level_for('gemini-3-flash-preview', 'minimal'), 'minimal', 'gemini-3-flash-preview: minimal -> minimal');
is(_thinking_level_for('gemini-3-flash-preview', 'none'),    'minimal', 'gemini-3-flash-preview: none -> minimal');
is(_thinking_level_for('gemini-3-flash-preview', 'xhigh'),   'high',    'gemini-3-flash-preview: xhigh -> high');
is(_thinking_level_for('gemini-3-flash-preview', 'max'),     'high',    'gemini-3-flash-preview: max -> high');

# gemini-3.5-flash (previous default) is also full-vocabulary: medium passes.
is(_thinking_level_for('gemini-3.5-flash', 'medium'), 'medium',
  'gemini-3.5-flash: medium -> medium (no more binary collapse on flash)');

# gemini-3.1-pro family: low|medium|high, NO minimal -> minimal/none clamp to low.
is(_thinking_level_for('gemini-3.1-pro-preview', 'minimal'), 'low',    'gemini-3.1-pro-preview: minimal clamps to low');
is(_thinking_level_for('gemini-3.1-pro-preview', 'none'),    'low',    'gemini-3.1-pro-preview: none clamps to low');
is(_thinking_level_for('gemini-3.1-pro-preview', 'low'),     'low',    'gemini-3.1-pro-preview: low -> low');
is(_thinking_level_for('gemini-3.1-pro-preview', 'medium'),  'medium', 'gemini-3.1-pro-preview: medium -> medium');
is(_thinking_level_for('gemini-3.1-pro-preview', 'high'),    'high',   'gemini-3.1-pro-preview: high -> high');
is(_thinking_level_for('gemini-3.1-pro-preview', 'max'),     'high',   'gemini-3.1-pro-preview: max -> high');

# gemini-3-pro family: low|high only -> minimal AND medium clamp to low.
is(_thinking_level_for('gemini-3-pro-preview', 'minimal'), 'low',  'gemini-3-pro-preview: minimal clamps to low');
is(_thinking_level_for('gemini-3-pro-preview', 'medium'),  'low',  'gemini-3-pro-preview: medium clamps to low');
is(_thinking_level_for('gemini-3-pro-preview', 'low'),     'low',  'gemini-3-pro-preview: low -> low');
is(_thinking_level_for('gemini-3-pro-preview', 'high'),    'high', 'gemini-3-pro-preview: high -> high');

# Non-Gemini-3 / unknown models keep the universally-accepted binary collapse.
is(_thinking_level_for('gemini-2.0-flash', 'medium'), 'low',  'gemini-2.0-flash: binary fallback medium -> low');
is(_thinking_level_for('gemini-2.0-flash', 'max'),    'high', 'gemini-2.0-flash: binary fallback max -> high');

# No model at all on the value object: same binary fallback.
my %no_model_kw = Langertha::Reasoning->new( effort => 'medium' )->to('gemini');
is($no_model_kw{thinkingConfig}{thinkingLevel}, 'low',
  'no model: binary fallback medium -> low');

# --- thinking_budget -> generationConfig.thinkingConfig.thinkingBudget (karr #20) ---

# Gemini 2.5 with integer thinking_budget: emit integer, no level
my $gemini_25 = Langertha::Engine::Gemini->new(
  api_key => 'k', model => 'gemini-2.5-pro', thinking_budget => 2048,
);
my $g25 = $json->decode($gemini_25->chat('hi')->content);
is($g25->{generationConfig}{thinkingConfig}{thinkingBudget}, 2048,
  'gemini-2.5-pro emits integer thinkingBudget');
ok(!exists $g25->{generationConfig}{thinkingConfig}{thinkingLevel},
  'gemini-2.5-pro does NOT emit thinkingLevel');

# Gemini 2.5 flash variant
my $gemini_25f = Langertha::Engine::Gemini->new(
  api_key => 'k', model => 'gemini-2.5-flash', thinking_budget => 512,
);
my $g25f = $json->decode($gemini_25f->chat('hi')->content);
is($g25f->{generationConfig}{thinkingConfig}{thinkingBudget}, 512,
  'gemini-2.5-flash emits integer thinkingBudget');

# Gemini 2.5 with NO thinking_budget: nothing emitted
my $gemini_25_none = Langertha::Engine::Gemini->new(
  api_key => 'k', model => 'gemini-2.5-pro',
);
my $g25n = $json->decode($gemini_25_none->chat('hi')->content);
ok(!exists $g25n->{generationConfig}{thinkingConfig},
  'gemini-2.5-pro omits thinkingConfig when thinking_budget unset');

# --- thinking_budget survives in the streaming request (karr #53) ---
# chat_stream_request used to gate on has_reasoning_effort alone, silently
# dropping a thinking_budget-only engine's budget on the wire.
my $gemini_25_stream = Langertha::Engine::Gemini->new(
  api_key => 'k', model => 'gemini-2.5-pro', thinking_budget => 2048,
);
my $g25s = $json->decode($gemini_25_stream->chat_stream('hi')->content);
is($g25s->{generationConfig}{thinkingConfig}{thinkingBudget}, 2048,
  'gemini-2.5-pro streaming emits integer thinkingBudget');
ok(!exists $g25s->{generationConfig}{thinkingConfig}{thinkingLevel},
  'gemini-2.5-pro streaming does NOT emit thinkingLevel');

# --- already-Gemini-shaped messages pass through (karr #53) ---
# chat_stream_request lacked the elsif ($message->{parts}) branch that
# chat_request has, so tool-result messages were re-wrapped as text.
my $gemini_parts = Langertha::Engine::Gemini->new(
  api_key => 'k', model => 'gemini-2.0-flash',
);
my $parts_msg = {
  role => 'user',
  parts => [{ text => 'already shaped' }],
};
my $parts_chat = $json->decode($gemini_parts->chat($parts_msg)->content);
my $parts_stream = $json->decode($gemini_parts->chat_stream($parts_msg)->content);
is_deeply($parts_chat->{contents}, [ $parts_msg ],
  'chat passes through already-Gemini-shaped messages');
is_deeply($parts_stream->{contents}, [ $parts_msg ],
  'streaming passes through already-Gemini-shaped messages');

# --- fail-loud wire-truth: exactly one native control per generation ---

# Conflict: effort + thinking_budget together croaks on any model/generation.
eval {
  Langertha::Reasoning->new(
    effort => 'high',
    thinking_budget => 2048,
    model => 'gemini-3.5-flash',
  );
};
like($@, qr/mutually exclusive/i,
  'effort + thinking_budget croaks on Gemini 3');

eval {
  Langertha::Reasoning->new(
    effort => 'high',
    thinking_budget => 2048,
    model => 'gemini-2.5-pro',
  );
};
like($@, qr/mutually exclusive/i,
  'effort + thinking_budget croaks on Gemini 2.5 (generation-agnostic)');

# Conflict: thinking_budget on Gemini 3 / non-Gemini-2.5 model croaks.
eval {
  Langertha::Reasoning->new(
    thinking_budget => 2048,
    model => 'gemini-3.5-flash',
  );
};
like($@, qr/only valid on Gemini 2\.5/i,
  'thinking_budget on Gemini 3 croaks');

eval {
  Langertha::Reasoning->new(
    thinking_budget => 2048,
    model => 'claude-opus-4-8',
  );
};
like($@, qr/only valid on Gemini 2\.5/i,
  'thinking_budget on a non-Gemini model croaks');

# Conflict: reasoning_effort on Gemini 2.5 croaks (Gemini 2.5 takes the
# integer budget, not the level vocabulary). The croak surfaces at request
# build time (chat_request -> reasoning_kwargs -> Langertha::Reasoning::BUILD),
# not at engine construction.
my $bad_g25 = eval {
  my $e = Langertha::Engine::Gemini->new(
    api_key => 'k', model => 'gemini-2.5-pro',
    reasoning_effort => 'high',
  );
  $e->chat('hi');    # forces reasoning_kwargs -> Reasoning->new -> BUILD
  return $e;
};
like($@, qr/not valid on Gemini 2\.5/i,
  'reasoning_effort on Gemini 2.5 croaks at request build (no wire sent)');

# Gemini 2.5 chat() does NOT send thinkingLevel (no level vocabulary on
# Gemini 2.5; only the budget branch is allowed).
eval {
  my $e = Langertha::Engine::Gemini->new(
    api_key => 'k', model => 'gemini-2.5-pro',
  );
  # construction alone is fine — only emit when a knob is set. Confirm no
  # thinkingConfig leaks when neither field is set.
  my $body = $json->decode($e->chat('hi')->content);
  ok(!exists $body->{generationConfig}{thinkingConfig},
    'gemini-2.5-pro with no knobs emits no thinkingConfig');
};

done_testing;
