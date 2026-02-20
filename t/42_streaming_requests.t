#!/usr/bin/env perl
use strict;
use warnings;
use Test2::Bundle::More;
use JSON::MaybeXS;

use Langertha::Engine::OpenAI;
use Langertha::Engine::Ollama;
use Langertha::Engine::Anthropic;
use Langertha::Engine::Groq;
use Langertha::Engine::Mistral;
use Langertha::Engine::DeepSeek;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

plan(24);

my $ollama_testurl = 'http://testollama:12345';

# OpenAI streaming request
my $openai = Langertha::Engine::OpenAI->new(
  api_key => 'test-key',
  model => 'gpt-4o-mini',
);
my $openai_stream_req = $openai->chat_stream('test prompt');
my $openai_data = $json->decode($openai_stream_req->content);
is($openai_data->{stream}, JSON->true, 'OpenAI stream request has stream=true');
is($openai_data->{model}, 'gpt-4o-mini', 'OpenAI model set correctly');
is($openai_stream_req->method, 'POST', 'OpenAI uses POST');
is($openai->stream_format, 'sse', 'OpenAI uses SSE format');

# Ollama streaming request
my $ollama = Langertha::Engine::Ollama->new(
  url => $ollama_testurl,
  model => 'llama3.1',
);
my $ollama_stream_req = $ollama->chat_stream('test prompt');
my $ollama_data = $json->decode($ollama_stream_req->content);
is($ollama_data->{stream}, JSON->true, 'Ollama stream request has stream=true');
is($ollama_data->{model}, 'llama3.1', 'Ollama model set correctly');
is($ollama_stream_req->method, 'POST', 'Ollama uses POST');
is($ollama->stream_format, 'ndjson', 'Ollama uses NDJSON format');

# Anthropic streaming request
my $anthropic = Langertha::Engine::Anthropic->new(
  api_key => 'test-key',
  model => 'claude-3-5-sonnet-20240620',
);
my $anthropic_stream_req = $anthropic->chat_stream('test prompt');
my $anthropic_data = $json->decode($anthropic_stream_req->content);
is($anthropic_data->{stream}, JSON->true, 'Anthropic stream request has stream=true');
is($anthropic_data->{model}, 'claude-3-5-sonnet-20240620', 'Anthropic model set correctly');
is($anthropic_stream_req->method, 'POST', 'Anthropic uses POST');
is($anthropic->stream_format, 'sse', 'Anthropic uses SSE format');

# Groq streaming request (inherits from OpenAI)
my $groq = Langertha::Engine::Groq->new(
  api_key => 'test-key',
  model => 'llama-3.3-70b-versatile',
);
my $groq_stream_req = $groq->chat_stream('test prompt');
my $groq_data = $json->decode($groq_stream_req->content);
is($groq_data->{stream}, JSON->true, 'Groq stream request has stream=true');
is($groq_data->{model}, 'llama-3.3-70b-versatile', 'Groq model set correctly');
is($groq->stream_format, 'sse', 'Groq uses SSE format');

# Mistral streaming request (inherits from OpenAI)
my $mistral = Langertha::Engine::Mistral->new(
  api_key => 'test-key',
  model => 'mistral-large-latest',
);
my $mistral_stream_req = $mistral->chat_stream('test prompt');
my $mistral_data = $json->decode($mistral_stream_req->content);
is($mistral_data->{stream}, JSON->true, 'Mistral stream request has stream=true');
is($mistral_data->{model}, 'mistral-large-latest', 'Mistral model set correctly');
is($mistral->stream_format, 'sse', 'Mistral uses SSE format');

# DeepSeek streaming request (inherits from OpenAI)
my $deepseek = Langertha::Engine::DeepSeek->new(
  api_key => 'test-key',
  model => 'deepseek-chat',
);
my $deepseek_stream_req = $deepseek->chat_stream('test prompt');
my $deepseek_data = $json->decode($deepseek_stream_req->content);
is($deepseek_data->{stream}, JSON->true, 'DeepSeek stream request has stream=true');
is($deepseek_data->{model}, 'deepseek-chat', 'DeepSeek model set correctly');
is($deepseek->stream_format, 'sse', 'DeepSeek uses SSE format');

# Test with system prompt
my $openai_sys = Langertha::Engine::OpenAI->new(
  api_key => 'test-key',
  model => 'gpt-4o-mini',
  system_prompt => 'You are helpful',
);
my $sys_req = $openai_sys->chat_stream('hi');
my $sys_data = $json->decode($sys_req->content);
is($sys_data->{messages}[0]{role}, 'system', 'System prompt included');
is($sys_data->{messages}[0]{content}, 'You are helpful', 'System prompt content correct');
is($sys_data->{messages}[1]{content}, 'hi', 'User message after system prompt');

done_testing;
