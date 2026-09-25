#!/usr/bin/env perl
# ABSTRACT: Provider manifest Builder: engine -> manifest, offline

use strict;
use warnings;

use Test2::Bundle::More;

use Langertha::Manifest::Builder;
use Langertha::Engine::OpenAI;
use Langertha::Engine::OpenAIResponses;
use Langertha::Engine::Anthropic;
use Langertha::Engine::vLLM;
use Langertha::Engine::Ollama;
use Langertha::Engine::Gemini;
use Langertha::Engine::Whisper;

# The Builder is how Knarr and Skeid publish what they expose. Two properties
# matter above all: the manifest tells the truth about the engine (dialect from
# the engine family, capabilities straight from engine_capabilities — the same
# registry chat_f's rewrites read), and it never carries a secret.

delete @ENV{qw( LANGERTHA_OLLAMA_API_KEY LANGERTHA_VLLM_API_KEY )};

my $SENTINEL = 'sk-SENTINEL-must-never-appear';

sub caps_of {
  my ( $manifest, $i ) = @_;
  my $caps = $manifest->models->[ $i // 0 ]->capabilities;
  return { map { $_ => 1 } grep { $caps->{$_} } keys %$caps };
}

subtest 'OpenAI' => sub {
  my $engine = Langertha::Engine::OpenAI->new( api_key => $SENTINEL );
  my $m = Langertha::Manifest::Builder->from_engine($engine);
  isa_ok $m, 'Langertha::Manifest';
  is $m->provider_id, 'openai', 'provider_id from class';
  is $m->issuer, 'https://api.openai.com', 'issuer is the url origin';
  my $ep = $m->endpoint('chat');
  is $ep->dialect, 'openai-chat', 'OpenAIBase family -> openai-chat';
  is $ep->base_url, 'https://api.openai.com/v1', 'base_url is the engine url';
  is $ep->auth_ref, 'api', 'required key -> auth_ref';
  is $m->auth_entry('api')->type, 'api_key', 'auth type api_key';
  is $m->models->[0]->id, $engine->chat_model, 'default model is chat_model';
  is_deeply caps_of($m), $engine->engine_capabilities, 'capabilities are engine_capabilities verbatim';
  ok $m->models->[0]->supports($_), "supports $_" for qw( chat streaming tools_native tool_choice_named );
  unlike $m->to_json, qr/\Q$SENTINEL\E/, 'the api_key never reaches the manifest';
};

subtest 'OpenAIResponses is the responses dialect' => sub {
  my $m = Langertha::Manifest::Builder->from_engine(
    Langertha::Engine::OpenAIResponses->new( api_key => $SENTINEL ) );
  is $m->endpoint('chat')->dialect, 'responses', 'most specific class wins over OpenAIBase';
};

subtest 'Anthropic, with per-model capabilities' => sub {
  my $engine = Langertha::Engine::Anthropic->new( api_key => $SENTINEL );
  my $m = Langertha::Manifest::Builder->from_engine( $engine,
    models => [ 'claude-sonnet-4-6', 'claude-sonnet-5' ] );
  is $m->endpoint('chat')->dialect, 'anthropic', 'AnthropicBase family -> anthropic';
  is $m->endpoint('chat')->base_url, 'https://api.anthropic.com', 'base_url is the engine url';
  is $m->endpoint('chat')->auth_ref, 'api', 'required key';
  # Anthropic's model_capability_corrections clear temperature on sonnet-5
  # (ADR 0019 layer 3): the manifest must reflect the model, not the default.
  my $old = $m->models->[0];
  my $new = $m->models->[1];
  is $old->id, 'claude-sonnet-4-6', 'first model';
  ok $old->supports('temperature'), 'sonnet-4-6 accepts temperature';
  ok !$new->supports('temperature'), 'sonnet-5 does not (model-scoped correction applied)';
  my $probe = Langertha::Engine::Anthropic->new( api_key => 'x', chat_model => 'claude-sonnet-5' );
  is_deeply caps_of( $m, 1 ), $probe->engine_capabilities, 'equals engine_capabilities for that model';
  unlike $m->to_json, qr/\Q$SENTINEL\E/, 'no secret';
};

subtest 'vLLM with a url and no key' => sub {
  my $engine = Langertha::Engine::vLLM->new( url => 'http://gpu01.lan:8000/v1', model => 'qwen3' );
  my $m = Langertha::Manifest::Builder->from_engine($engine);
  is $m->provider_id, 'vllm', 'vLLM -> vllm';
  is $m->issuer, 'http://gpu01.lan:8000', 'issuer keeps a non-default port';
  my $ep = $m->endpoint('chat');
  is $ep->dialect, 'openai-chat', 'vLLM is openai-chat';
  is $ep->base_url, 'http://gpu01.lan:8000/v1', 'base_url';
  is $ep->auth_ref, undef, 'optional key, none configured -> no auth';
  is_deeply $m->auth, [], 'no auth entries';
  is $m->models->[0]->id, 'qwen3', 'model';
  ok $m->models->[0]->supports('prefix_caching'), 'RuntimeKnobs capability emitted';
  ok $m->models->[0]->supports('runtime_metrics'), 'MetricsPoll capability emitted';
  is_deeply caps_of($m), $engine->engine_capabilities, 'capabilities verbatim';
};

subtest 'vLLM with a configured key announces api_key, never the key' => sub {
  my $m = Langertha::Manifest::Builder->from_engine(
    Langertha::Engine::vLLM->new( url => 'http://gpu01.lan:8000/v1', api_key => $SENTINEL ) );
  is $m->endpoint('chat')->auth_ref, 'api', 'optional key configured -> auth';
  unlike $m->to_json, qr/\Q$SENTINEL\E/, 'no secret';
};

subtest 'Ollama native' => sub {
  my $engine = Langertha::Engine::Ollama->new( url => 'http://localhost:11434' );
  my $m = Langertha::Manifest::Builder->from_engine( $engine, models => [ 'llama3.3', 'qwen3:8b' ] );
  is $m->endpoint('chat')->dialect, 'ollama', 'Ollama -> ollama';
  is $m->endpoint('chat')->auth_ref, undef, 'local Ollama needs no auth';
  is $m->issuer, 'http://localhost:11434', 'issuer';
  is scalar @{ $m->models }, 2, 'two models';
  ok $m->models->[1]->supports('keep_alive'), 'KeepAlive capability';
  ok $m->models->[1]->supports('embedding'), 'embedding capability';
};

subtest 'overrides and auth=none' => sub {
  my $m = Langertha::Manifest::Builder->from_engine(
    Langertha::Engine::OpenAI->new( api_key => $SENTINEL ),
    provider_id => 'my-knarr',
    issuer      => 'https://knarr.example',
    base_url    => 'https://knarr.example/v1',
    endpoint_id => 'openai',
    auth        => 'none',
  );
  is $m->provider_id, 'my-knarr', 'provider_id override';
  is $m->issuer, 'https://knarr.example', 'issuer override';
  is $m->endpoint('openai')->base_url, 'https://knarr.example/v1', 'public base_url, not the upstream one';
  is $m->endpoint('openai')->auth_ref, undef, 'auth none';
  unlike $m->to_json, qr/api\.openai\.com/, 'upstream url does not leak when overridden';
};

subtest 'multi-endpoint build (Knarr shape)' => sub {
  my $b = Langertha::Manifest::Builder->new( provider_id => 'knarr', issuer => 'https://knarr.example' );
  $b->add_engine( Langertha::Engine::OpenAI->new( api_key => $SENTINEL ),
    endpoint_id => 'openai', base_url => 'https://knarr.example/v1', models => ['m1'] );
  $b->add_engine( Langertha::Engine::Anthropic->new( api_key => $SENTINEL ),
    endpoint_id => 'anthropic', base_url => 'https://knarr.example', models => ['m1'] );
  $b->add_endpoint( id => 'ollama', dialect => 'ollama', base_url => 'https://knarr.example' );
  $b->add_model( id => 'm1', endpoint_ref => 'ollama', capabilities => { chat => 1 } );
  my $m = $b->manifest;
  is scalar @{ $m->endpoints }, 3, 'three endpoints';
  is scalar @{ $m->auth }, 1, 'one shared auth entry';
  is scalar @{ $m->models }, 3, 'the same model id on three endpoints';
  is $m->endpoint('anthropic')->auth_ref, 'api', 'second engine reuses the auth entry';
  unlike $m->to_json, qr/\Q$SENTINEL\E/, 'no secret';
  ok !eval { $b->add_engine( Langertha::Engine::OpenAI->new( api_key => 'x' ), endpoint_id => 'openai' ); 1 },
    'duplicate endpoint id croaks';
};

subtest 'Gemini dialect and model-aware capabilities' => sub {
  my $m = Langertha::Manifest::Builder->from_engine(
    Langertha::Engine::Gemini->new( api_key => $SENTINEL ), models => [ 'gemini-2.5-pro', 'gemini-3-pro' ] );
  is $m->endpoint('chat')->dialect, 'gemini', 'gemini';
  ok $m->models->[0]->supports('thinking_budget'), 'engine-emitted flag passes through for 2.5';
  ok !$m->models->[1]->supports('thinking_budget'), 'and not for 3';
};

subtest 'transcription-only engine has no dialect' => sub {
  ok !eval { Langertha::Manifest::Builder->from_engine(
    Langertha::Engine::Whisper->new( url => 'http://localhost:8000/v1' ) ); 1 }, 'Whisper croaks';
  like $@, qr/no manifest dialect/, 'message';
};

subtest 'the engine is not mutated' => sub {
  my $engine = Langertha::Engine::Anthropic->new( api_key => 'x', chat_model => 'claude-sonnet-4-6' );
  Langertha::Manifest::Builder->from_engine( $engine, models => ['claude-sonnet-5'] );
  is $engine->chat_model, 'claude-sonnet-4-6', 'chat_model untouched';
};

done_testing;
