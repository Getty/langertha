#!/usr/bin/env perl
# ABSTRACT: Test AKI.IO native API request generation and mock responses

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;
use HTTP::Response;

use Langertha::Engine::AKI;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

# --- Chat request format ---

my $aki = Langertha::Engine::AKI->new(
  api_key => 'testkey',
  model => 'llama3_8b_chat',
  system_prompt => 'systemprompt',
  temperature => 0.5,
  top_k => 40,
  top_p => 0.9,
  max_gen_tokens => 2000,
);

my $request = $aki->chat('testprompt');
is($request->uri, 'https://aki.io/api/call/llama3_8b_chat', 'AKI chat request uri is correct');
is($request->method, 'POST', 'AKI chat request method is correct');
is($request->header('Content-Type'), 'application/json; charset=utf-8', 'AKI chat request JSON Content Type is set');

my $data = $json->decode($request->content);

# chat_context is a JSON string (not native array) per AKI API convention
my $expected_chat_context = $json->encode([{
  content => "systemprompt", role => "system",
},{
  content => "testprompt", role => "user",
}]);

is($data->{key}, 'testkey', 'AKI request has key in body');
is($data->{temperature}, 0.5, 'AKI request has temperature');
is($data->{top_k}, 40, 'AKI request has top_k');
is($data->{top_p}, 0.9, 'AKI request has top_p');
is($data->{max_gen_tokens}, 2000, 'AKI request has max_gen_tokens');
is($data->{wait_for_result}, JSON->true, 'AKI request has wait_for_result');

# chat_context should be a JSON-encoded string
ok(!ref $data->{chat_context}, 'chat_context is a string (not a reference)');
my $decoded_context = $json->decode($data->{chat_context});
is_deeply($decoded_context, [{
  content => "systemprompt", role => "system",
},{
  content => "testprompt", role => "user",
}], 'AKI chat_context decodes to correct messages');

# No Authorization header (key is in body)
ok(!$request->header('Authorization'), 'AKI request has no Authorization header');

# --- Chat response parsing ---

my $mock_response = HTTP::Response->new(200, 'OK');
$mock_response->content($json->encode({
  success => JSON->true,
  text => 'Hello from AKI!',
  total_duration => 0.7,
  model_name => 'Meta-Llama-3-8B-Instruct',
}));
$mock_response->header('Content-Type' => 'application/json');

my $result = $aki->chat_response($mock_response);
is($result, 'Hello from AKI!', 'AKI chat response parsed correctly');

# --- Chat error response ---

my $error_response = HTTP::Response->new(200, 'OK');
$error_response->content($json->encode({
  success => JSON->false,
  error => 'Invalid API key',
}));
$error_response->header('Content-Type' => 'application/json');

eval { $aki->chat_response($error_response) };
like($@, qr/API error.*Invalid API key/, 'AKI error response throws with message');

# --- list_models request format ---

my $lm_request = $aki->list_models_request;
is($lm_request->uri, 'https://aki.io/api/endpoints?key=testkey', 'AKI list_models request uri is correct');
is($lm_request->method, 'GET', 'AKI list_models request method is GET');

# --- list_models response parsing ---

my $lm_response = HTTP::Response->new(200, 'OK');
$lm_response->content($json->encode({
  endpoints => ['llama3_8b_chat', 'flux_schnell', 'qwen3_chat'],
}));
$lm_response->header('Content-Type' => 'application/json');

my $endpoints = $lm_request->response_call->($lm_response);
is_deeply($endpoints, ['llama3_8b_chat', 'flux_schnell', 'qwen3_chat'],
  'AKI list_models response parsed correctly');

# --- endpoint_details request format ---

my $ed_request = $aki->endpoint_details_request('llama3_8b_chat');
is($ed_request->uri, 'https://aki.io/api/endpoints/llama3_8b_chat?key=testkey',
  'AKI endpoint_details request uri is correct');
is($ed_request->method, 'GET', 'AKI endpoint_details request method is GET');

# --- endpoint_details response parsing ---

my $ed_response = HTTP::Response->new(200, 'OK');
$ed_response->content($json->encode({
  name => 'llama3_8b_chat',
  title => 'LLama 3.x Chat',
  description => 'Llama 3.x Instruct Chat example API',
  version => 2,
  http_methods => ['GET', 'POST'],
  parameter_description => {
    input => {
      chat_context => { type => 'json', required => JSON->false },
      temperature => { type => 'float', minimum => 0, maximum => 1, default => 0.8 },
    },
    output => {
      text => { type => 'string' },
      model_name => { type => 'string' },
    },
  },
}));
$ed_response->header('Content-Type' => 'application/json');

my $details = $ed_request->response_call->($ed_response);
is($details->{name}, 'llama3_8b_chat', 'endpoint_details name is correct');
is($details->{title}, 'LLama 3.x Chat', 'endpoint_details title is correct');
ok($details->{parameter_description}{input}{chat_context}, 'endpoint_details has chat_context param');

# --- Chat without optional params ---

my $aki_minimal = Langertha::Engine::AKI->new(
  api_key => 'testkey',
  model => 'llama3_8b_chat',
);

my $min_request = $aki_minimal->chat('hello');
my $min_data = $json->decode($min_request->content);
is($min_data->{key}, 'testkey', 'AKI minimal request has key');
is($min_data->{wait_for_result}, JSON->true, 'AKI minimal request has wait_for_result');
ok(!exists $min_data->{temperature}, 'AKI minimal request has no temperature');
ok(!exists $min_data->{top_k}, 'AKI minimal request has no top_k');

# chat_context is JSON string
ok(!ref $min_data->{chat_context}, 'minimal chat_context is a string');
my $min_decoded = $json->decode($min_data->{chat_context});
is_deeply($min_decoded, [{
  content => "hello", role => "user",
}], 'AKI minimal chat_context decodes correctly');

# --- openai() method ---

{
  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  my $aki_openai = $aki->openai;
  isa_ok($aki_openai, 'Langertha::Engine::AKIOpenAI');
  is($aki_openai->model, 'llama3-chat-8b', 'openai() uses AKIOpenAI default model');
  is($aki_openai->api_key, 'testkey', 'openai() passes api_key');
  ok(scalar @warnings >= 1, 'openai() without explicit model emits warning');
  like($warnings[0] || '', qr/cannot be mapped/, 'warning mentions model mapping');
}

# openai() with explicit model does not warn
{
  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  my $aki_openai = $aki->openai(model => 'llama3-chat-8b');
  is($aki_openai->model, 'llama3-chat-8b', 'openai(model => ...) uses given model');
  is(scalar @warnings, 0, 'openai() with explicit model does not warn');
}

done_testing;
