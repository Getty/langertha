#!/usr/bin/env perl

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;

use Langertha::Engine::Anthropic;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

my $anthropic = Langertha::Engine::Anthropic->new(
  api_key => 'test-key',
  model => 'claude-sonnet-4-5-20250929',
  system_prompt => 'You are a helpful assistant',
  response_size => 1024,
);

# Test: mcp_servers defaults to empty
is_deeply($anthropic->mcp_servers, [], 'mcp_servers defaults to empty');
is($anthropic->tool_max_iterations, 10, 'tool_max_iterations defaults to 10');

# Test: format_tools converts MCP format to Anthropic format
{
  my $mcp_tools = [
    {
      name => 'echo',
      description => 'Echo the input text',
      inputSchema => {
        type => 'object',
        properties => { message => { type => 'string' } },
        required => ['message'],
      },
    },
    {
      name => 'add',
      description => 'Add two numbers',
      inputSchema => {
        type => 'object',
        properties => {
          a => { type => 'number' },
          b => { type => 'number' },
        },
        required => ['a', 'b'],
      },
    },
  ];

  my $formatted = $anthropic->format_tools($mcp_tools);
  is(scalar @$formatted, 2, 'two tools formatted');

  is($formatted->[0]{name}, 'echo', 'first tool name');
  is($formatted->[0]{description}, 'Echo the input text', 'first tool description');
  ok($formatted->[0]{input_schema}, 'input_schema present (snake_case)');
  ok(!exists $formatted->[0]{inputSchema}, 'inputSchema removed (camelCase)');
  is($formatted->[0]{input_schema}{type}, 'object', 'schema type preserved');
  is_deeply($formatted->[0]{input_schema}{required}, ['message'], 'schema required preserved');

  is($formatted->[1]{name}, 'add', 'second tool name');
}

# Test: chat_request includes tools in body
{
  my $tools = [
    { name => 'echo', description => 'Echo', input_schema => { type => 'object' } },
  ];

  my $request = $anthropic->chat_request(
    [{ role => 'user', content => 'Use the echo tool' }],
    tools => $tools,
  );

  is($request->method, 'POST', 'POST method');
  is($request->uri, 'https://api.anthropic.com/v1/messages', 'correct URI');

  my $body = $json->decode($request->content);
  ok($body->{tools}, 'tools field present in request body');
  is(scalar @{$body->{tools}}, 1, 'one tool in body');
  is($body->{tools}[0]{name}, 'echo', 'tool name in body');
  is($body->{model}, 'claude-sonnet-4-5-20250929', 'model in body');
  is($body->{max_tokens}, 1024, 'max_tokens in body');
  ok(!exists $body->{system}, 'no system in body when not in messages');
}

# Test: response_tool_calls extracts tool_use blocks
{
  my $data = {
    content => [
      { type => 'text', text => 'I will echo your message.' },
      { type => 'tool_use', id => 'toolu_abc123', name => 'echo', input => { message => 'hello' } },
    ],
    stop_reason => 'tool_use',
  };

  my $calls = $anthropic->response_tool_calls($data);
  is(scalar @$calls, 1, 'one tool call extracted');
  is($calls->[0]{type}, 'tool_use', 'type is tool_use');
  is($calls->[0]{id}, 'toolu_abc123', 'tool_use id');
  is($calls->[0]{name}, 'echo', 'tool name');
  is_deeply($calls->[0]{input}, { message => 'hello' }, 'tool input');
}

# Test: response_tool_calls returns empty for text-only response
{
  my $data = {
    content => [
      { type => 'text', text => 'Just a normal response.' },
    ],
    stop_reason => 'end_turn',
  };

  my $calls = $anthropic->response_tool_calls($data);
  is(scalar @$calls, 0, 'no tool calls in text-only response');
}

# Test: response_tool_calls handles multiple tool calls
{
  my $data = {
    content => [
      { type => 'tool_use', id => 'toolu_1', name => 'echo', input => { message => 'a' } },
      { type => 'tool_use', id => 'toolu_2', name => 'add', input => { a => 1, b => 2 } },
    ],
  };

  my $calls = $anthropic->response_tool_calls($data);
  is(scalar @$calls, 2, 'two tool calls extracted');
  is($calls->[0]{name}, 'echo', 'first call name');
  is($calls->[1]{name}, 'add', 'second call name');
}

# Test: response_text_content extracts text
{
  my $data = {
    content => [
      { type => 'text', text => 'Hello ' },
      { type => 'text', text => 'world!' },
    ],
  };

  is($anthropic->response_text_content($data), 'Hello world!', 'text content joined');
}

# Test: response_text_content skips non-text blocks
{
  my $data = {
    content => [
      { type => 'text', text => 'Before tool. ' },
      { type => 'tool_use', id => 'toolu_1', name => 'echo', input => {} },
      { type => 'text', text => 'After tool.' },
    ],
  };

  is($anthropic->response_text_content($data), 'Before tool. After tool.', 'text content skips tool_use');
}

# Test: format_tool_results builds correct message structure
{
  my $data = {
    content => [
      { type => 'text', text => 'Let me echo that.' },
      { type => 'tool_use', id => 'toolu_abc', name => 'echo', input => { message => 'hi' } },
    ],
  };

  my $results = [
    {
      tool_call => { type => 'tool_use', id => 'toolu_abc', name => 'echo', input => { message => 'hi' } },
      result => {
        content => [{ type => 'text', text => 'Echo: hi' }],
        isError => JSON->false,
      },
    },
  ];

  my @messages = $anthropic->format_tool_results($data, $results);
  is(scalar @messages, 2, 'two messages returned');

  # First message: assistant with original content
  is($messages[0]{role}, 'assistant', 'first message is assistant');
  is(scalar @{$messages[0]{content}}, 2, 'assistant content has 2 blocks');
  is($messages[0]{content}[0]{type}, 'text', 'first block is text');
  is($messages[0]{content}[1]{type}, 'tool_use', 'second block is tool_use');

  # Second message: user with tool results
  is($messages[1]{role}, 'user', 'second message is user');
  is(scalar @{$messages[1]{content}}, 1, 'one tool result');
  is($messages[1]{content}[0]{type}, 'tool_result', 'type is tool_result');
  is($messages[1]{content}[0]{tool_use_id}, 'toolu_abc', 'tool_use_id matches');
  is($messages[1]{content}[0]{content}[0]{type}, 'text', 'result content type');
  is($messages[1]{content}[0]{content}[0]{text}, 'Echo: hi', 'result content text');
  ok(!exists $messages[1]{content}[0]{is_error}, 'no is_error when not an error');
}

# Test: format_tool_results with error result
{
  my $data = {
    content => [
      { type => 'tool_use', id => 'toolu_err', name => 'fail', input => {} },
    ],
  };

  my $results = [
    {
      tool_call => { type => 'tool_use', id => 'toolu_err', name => 'fail', input => {} },
      result => {
        content => [{ type => 'text', text => 'Something went wrong' }],
        isError => JSON->true,
      },
    },
  ];

  my @messages = $anthropic->format_tool_results($data, $results);
  ok($messages[1]{content}[0]{is_error}, 'is_error set for error result');
}

done_testing;
