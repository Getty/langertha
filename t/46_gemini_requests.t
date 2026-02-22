#!/usr/bin/env perl
# ABSTRACT: Test Gemini engine request generation and model list

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;

use Langertha::Engine::Gemini;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

plan(8);

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
is($gemini->default_model, 'gemini-2.5-flash', 'Gemini default model is gemini-2.5-flash');

done_testing;
