#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use JSON::MaybeXS;
use Path::Tiny;

# Test response parsing for model listing APIs
# These tests verify that each engine can correctly parse API responses
# without making actual API calls

my $data_dir = path(__FILE__)->parent->child('data');

# Helper to load fixture JSON
sub load_fixture {
  my ($filename) = @_;
  my $file = $data_dir->child($filename);
  return decode_json($file->slurp_utf8);
}

# Helper to create mock HTTP::Response
sub mock_response {
  my ($json_data) = @_;
  require HTTP::Response;
  my $response = HTTP::Response->new(200, 'OK');
  $response->content(encode_json($json_data));
  $response->header('Content-Type' => 'application/json');
  return $response;
}

subtest 'OpenAI response parsing' => sub {
  plan tests => 3;

  use_ok('Langertha::Engine::OpenAI');

  my $fixture = load_fixture('openai_models.json');
  my $response = mock_response($fixture);

  # Create engine (will fail without API key, but that's ok for parsing test)
  my $engine = Langertha::Engine::OpenAI->new(api_key => 'test-key');

  # Test response parsing
  my $models = $engine->list_models_response($response);

  is(ref($models), 'ARRAY', 'Returns array of models');
  is(scalar(@$models), 5, 'Parsed 5 models from fixture');
};

subtest 'Anthropic response parsing' => sub {
  plan tests => 5;

  use_ok('Langertha::Engine::Anthropic');

  my $fixture = load_fixture('anthropic_models.json');
  my $response = mock_response($fixture);

  my $engine = Langertha::Engine::Anthropic->new(api_key => 'test-key');

  # Test response parsing
  my $data = $engine->list_models_response($response);

  is(ref($data), 'HASH', 'Returns hash with pagination data');
  is(ref($data->{data}), 'ARRAY', 'Has models array');
  is(scalar(@{$data->{data}}), 3, 'Parsed 3 models from fixture');
  is($data->{data}[0]{id}, 'claude-opus-4-6-20250514', 'First model ID correct');
};

subtest 'Gemini response parsing' => sub {
  plan tests => 5;

  use_ok('Langertha::Engine::Gemini');

  my $fixture = load_fixture('gemini_models.json');
  my $response = mock_response($fixture);

  my $engine = Langertha::Engine::Gemini->new(api_key => 'test-key');

  # Test response parsing
  my $data = $engine->list_models_response($response);

  is(ref($data), 'HASH', 'Returns hash with model data');
  is(ref($data->{models}), 'ARRAY', 'Has models array');
  is(scalar(@{$data->{models}}), 3, 'Parsed 3 models from fixture');
  is($data->{models}[0]{name}, 'models/gemini-2.0-flash-exp', 'First model name correct');
};

subtest 'Groq response parsing' => sub {
  plan tests => 3;

  use_ok('Langertha::Engine::Groq');

  my $fixture = load_fixture('groq_models.json');
  my $response = mock_response($fixture);

  my $engine = Langertha::Engine::Groq->new(api_key => 'test-key');

  # Test response parsing
  my $models = $engine->list_models_response($response);

  is(ref($models), 'ARRAY', 'Returns array of models');
  is(scalar(@$models), 4, 'Parsed 4 models from fixture');
};

subtest 'Mistral response parsing' => sub {
  plan tests => 3;

  use_ok('Langertha::Engine::Mistral');

  my $fixture = load_fixture('mistral_models.json');
  my $response = mock_response($fixture);

  my $engine = Langertha::Engine::Mistral->new(api_key => 'test-key');

  # Test response parsing
  my $models = $engine->list_models_response($response);

  is(ref($models), 'ARRAY', 'Returns array of models');
  is(scalar(@$models), 3, 'Parsed 3 models from fixture');
};

subtest 'DeepSeek response parsing' => sub {
  plan tests => 3;

  use_ok('Langertha::Engine::DeepSeek');

  my $fixture = load_fixture('deepseek_models.json');
  my $response = mock_response($fixture);

  my $engine = Langertha::Engine::DeepSeek->new(api_key => 'test-key');

  # Test response parsing
  my $models = $engine->list_models_response($response);

  is(ref($models), 'ARRAY', 'Returns array of models');
  is(scalar(@$models), 2, 'Parsed 2 models from fixture');
};

done_testing;
