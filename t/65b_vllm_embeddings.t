#!/usr/bin/env perl
# ABSTRACT: Offline tests for vLLM Embedding role composition (karr #70)

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;

use Langertha::Engine::vLLM;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

plan(11);

# --- Engine construction ---

my $vllm = Langertha::Engine::vLLM->new(
  url => 'http://test.invalid:8000/v1',
);

is($vllm->default_embedding_model, 'default',
  'default_embedding_model returns default');

is($vllm->embedding_model, 'default',
  'embedding_model resolves to default_embedding_model when unset');

ok($vllm->does('Langertha::Role::Embedding'),
  'vLLM composes Langertha::Role::Embedding');

# --- Supported operations include createEmbedding ---

my $ops = $vllm->_build_supported_operations;
ok((grep { $_ eq 'createEmbedding' } @$ops),
  '_build_supported_operations contains createEmbedding');

# --- Request generation ---

my $req = $vllm->embedding('hello world');
is($req->method, 'POST', 'embedding request method is POST');
is($req->uri, 'http://test.invalid:8000/v1/embeddings',
  'embedding request hits /v1/embeddings');
is($req->header('Content-Type'),
  'application/json; charset=utf-8',
  'embedding request sets JSON Content-Type');

my $data = $json->decode($req->content);
is_deeply($data, {
  model => 'default',
  input => 'hello world',
}, 'embedding request body decodes to { model: default, input: ... }');

# --- Explicit embedding_model flows through ---

my $custom = $vllm->new(
  url             => 'http://test.invalid:8000/v1',
  embedding_model => 'BAAI/bge-large-en-v1.5',
);
is($custom->embedding_model, 'BAAI/bge-large-en-v1.5',
  'explicit embedding_model is preserved');
my $custom_data = $json->decode($custom->embedding('hi')->content);
is($custom_data->{model}, 'BAAI/bge-large-en-v1.5',
  'explicit embedding_model flows into request body');
is($custom_data->{input}, 'hi',
  'explicit embedding input is preserved');

done_testing;
