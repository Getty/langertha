#!/usr/bin/env perl
# ABSTRACT: DeepSeek V3 vs V4 reasoning_effort wire dispatch (karr #20, #25)

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;

use Langertha::Engine::DeepSeek;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

plan(16);

# --- Default model is the current V4 flash line (karr #25) ---

is(Langertha::Engine::DeepSeek->new(api_key => 'k')->default_model,
  'deepseek-v4-flash', 'DeepSeek default_model is deepseek-v4-flash');

# --- V4 line: flat reasoning_effort ---

# deepseek-v4-flash accepts the full low|high|max ladder (server default
# high). The engine default model must therefore pass low through.
my $v4_default = Langertha::Engine::DeepSeek->new(
  api_key => 'k', reasoning_effort => 'low',
);
my $dd = $json->decode($v4_default->chat('hi')->content);
is($dd->{model}, 'deepseek-v4-flash',
  'default engine sends deepseek-v4-flash in the request body');
is($dd->{reasoning_effort}, 'low',
  'deepseek-v4-flash (default) emits flat reasoning_effort low');
ok(!exists $dd->{thinking},
  'deepseek-v4-flash does NOT emit legacy V3.2 thinking:{type:enabled}');

my $v4_flash = Langertha::Engine::DeepSeek->new(
  api_key => 'k', model => 'deepseek-v4-flash', reasoning_effort => 'max',
);
my $d4f = $json->decode($v4_flash->chat('hi')->content);
is($d4f->{reasoning_effort}, 'max',
  'deepseek-v4-flash emits flat reasoning_effort max');
ok(!exists $d4f->{thinking},
  'deepseek-v4-flash does NOT emit legacy V3.2 thinking');

# deepseek-v4-pro currently accepts only high|max; low is treated as high
# server-side, so the engine drops it instead of emitting a remapped value.
my $v4_pro = Langertha::Engine::DeepSeek->new(
  api_key => 'k', model => 'deepseek-v4-pro', reasoning_effort => 'high',
);
my $d4p = $json->decode($v4_pro->chat('hi')->content);
is($d4p->{reasoning_effort}, 'high',
  'deepseek-v4-pro emits flat reasoning_effort high');
ok(!exists $d4p->{thinking},
  'deepseek-v4-pro does NOT emit legacy V3.2 thinking');

my $v4_pro_low = Langertha::Engine::DeepSeek->new(
  api_key => 'k', model => 'deepseek-v4-pro', reasoning_effort => 'low',
);
my $d4pl = $json->decode($v4_pro_low->chat('hi')->content);
ok(!exists $d4pl->{reasoning_effort},
  'deepseek-v4-pro drops reasoning_effort low (server would remap to high)');
ok(!exists $d4pl->{thinking},
  'deepseek-v4-pro with low does NOT emit legacy V3.2 thinking either');

# --- V3.2 line: legacy thinking:{type:enabled} ---

my $v3_explicit = Langertha::Engine::DeepSeek->new(
  api_key => 'k', model => 'deepseek-v3', reasoning_effort => 'high',
);
my $d3 = $json->decode($v3_explicit->chat('hi')->content);
is_deeply($d3->{thinking}, { type => 'enabled' },
  'deepseek-v3 emits legacy thinking:{type:enabled}');
ok(!exists $d3->{reasoning_effort},
  'deepseek-v3 does NOT emit flat reasoning_effort');

my $v3_32 = Langertha::Engine::DeepSeek->new(
  api_key => 'k', model => 'deepseek-v3.2-exp', reasoning_effort => 'high',
);
my $d32 = $json->decode($v3_32->chat('hi')->content);
is_deeply($d32->{thinking}, { type => 'enabled' },
  'deepseek-v3.2-exp emits legacy thinking:{type:enabled}');
ok(!exists $d32->{reasoning_effort},
  'deepseek-v3.2-exp does NOT emit flat reasoning_effort');

# --- Unknown / future model id: default to V4 (safe current default) ---
# Conservative: unknown ids get the v4-pro ladder (high|max only).

my $unknown = Langertha::Engine::DeepSeek->new(
  api_key => 'k', model => 'deepseek-v99-ultra', reasoning_effort => 'high',
);
my $du = $json->decode($unknown->chat('hi')->content);
is($du->{reasoning_effort}, 'high',
  'unknown model id defaults to V4 flat reasoning_effort (not V3.2 thinking)');

my $unknown_low = Langertha::Engine::DeepSeek->new(
  api_key => 'k', model => 'deepseek-v99-ultra', reasoning_effort => 'low',
);
my $dul = $json->decode($unknown_low->chat('hi')->content);
ok(!exists $dul->{reasoning_effort},
  'unknown model id drops reasoning_effort low (conservative v4-pro ladder)');

done_testing;