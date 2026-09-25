#!/usr/bin/env perl
# ABSTRACT: chat_f puts every tools item on the wire in the engine's tool_wire_format
use strict;
use warnings;

use Test2::Bundle::More;
use lib 't/lib';

use JSON::MaybeXS;
use Langertha::Engine::OpenAI;
use Langertha::Engine::OpenAIResponses;
use Langertha::Engine::Anthropic;
use Langertha::Engine::Gemini;
use Langertha::Engine::Ollama;
use Langertha::Engine::NousResearch;
use Langertha::ServerTool;
use Langertha::Tool;
use Test::MockAsyncHTTP;

# karr k227 (ADR 0001): chat_f handed `tools` to chat_request raw, so a
# Langertha::Tool went out through TO_JSON in its canonical to_hash shape --
# which only the Anthropic wire reads; OpenAI, Gemini and Ollama got an invalid
# tool and answered 400. chat_f now shapes the list through the same one path
# as chat_stream_realtime_f (k221). What must NOT move: a hash that is already
# in the wire's own shape is the caller's wire intent and goes out byte for
# byte -- it carries the extras the value objects do not model
# (function.strict, cache_control) and the provider built-ins
# (web_search_20250305, google_search) the Tool door refuses.

my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );

my %reply = (
  openai    => { choices => [ { message => { role => 'assistant', content => 'ok' }, finish_reason => 'stop' } ] },
  anthropic => { id => 'msg_1', type => 'message', role => 'assistant',
    content => [ { type => 'text', text => 'ok' } ], stop_reason => 'end_turn' },
  gemini    => { candidates => [ { content => { role => 'model', parts => [ { text => 'ok' } ] }, finishReason => 'STOP' } ] },
  ollama    => { model => 'qwen3:8b', message => { role => 'assistant', content => 'ok' }, done => JSON->true },
  responses => { output => [ { type => 'message', role => 'assistant',
    content => [ { type => 'output_text', text => 'ok' } ] } ] },
);
$reply{hermes} = $reply{openai};

my %make = (
  openai    => sub { Langertha::Engine::OpenAI->new( api_key => 'k', model => 'gpt-4o-mini', @_ ) },
  anthropic => sub { Langertha::Engine::Anthropic->new( api_key => 'k', model => 'claude-sonnet-4-6', @_ ) },
  gemini    => sub { Langertha::Engine::Gemini->new( api_key => 'k', model => 'gemini-3-flash-preview', @_ ) },
  ollama    => sub { Langertha::Engine::Ollama->new( url => 'http://127.0.0.1:11434', model => 'qwen3:8b', @_ ) },
  responses => sub { Langertha::Engine::OpenAIResponses->new( api_key => 'k', model => 'gpt-5.6-luna', @_ ) },
  hermes    => sub { Langertha::Engine::NousResearch->new( api_key => 'k', model => 'Hermes-4-70B', @_ ) },
);

# ($engine, $mock) for one wire; the engine sends through the mock.
sub engine_for {
  my ($fmt) = @_;
  my $mock = Test::MockAsyncHTTP->new(
    responses => [ Test::MockAsyncHTTP->mock_json_response( $reply{$fmt} ) ] );
  my $engine = $make{$fmt}->( _async_http => $mock );
  is( $engine->tool_wire_format, $fmt, "engine speaks the $fmt tool wire" );
  return ( $engine, $mock );
}

# The raw request bytes chat_f sent for @tools.
sub chat_f_bytes {
  my ( $fmt, $tools ) = @_;
  my ( $engine, $mock ) = engine_for($fmt);
  my $response = $engine->chat_f( messages => ['hi'], tools => $tools )->get;
  ok( defined $response, "$fmt: chat_f answered" );
  my ($request) = $mock->requests;
  return $request->content;
}
sub chat_f_tools { $json->decode( chat_f_bytes(@_) )->{tools} }

# The bytes chat_request builds for the same tools when nothing reshapes them.
sub direct_bytes {
  my ( $fmt, $tools ) = @_;
  my ($engine) = engine_for($fmt);
  return $engine->chat_request( $engine->chat_messages('hi'), tools => $tools )->content;
}

my $schema = { type => 'object', properties => { a => { type => 'number' } }, required => ['a'] };

# Hashes that are already in each wire's own shape, extras and built-ins
# included, plus a typed item Langertha does not know (Moonshot's builtin
# function on an OpenAI-compatible wire): the provider judges those.
my %native = (
  openai => [
    { type => 'function', function => { name => 'add', description => 'Add', parameters => $schema, strict => JSON->true } },
    { type => 'builtin_function', function => { name => '$web_search' } },
  ],
  anthropic => [
    { type => 'web_search_20250305', name => 'web_search', max_uses => 1 },
    { name => 'add', description => 'Add', input_schema => $schema, cache_control => { type => 'ephemeral' } },
  ],
  gemini => [
    { google_search => {} },
    { functionDeclarations => [ { name => 'add', description => 'Add', parameters => $schema, behavior => 'BLOCKING' } ] },
  ],
  ollama => [
    { type => 'function', function => { name => 'add', description => 'Add', parameters => $schema } },
  ],
  responses => [
    { type => 'function', name => 'add', description => 'Add', parameters => $schema, strict => JSON->true },
    { type => 'web_search' },
  ],
  hermes => [
    { type => 'function', function => { name => 'add', description => 'Add', parameters => $schema } },
  ],
);

subtest 'pin: wire-shaped hashes go out byte for byte' => sub {
  for my $fmt (qw( openai anthropic gemini ollama responses hermes )) {
    is( chat_f_bytes( $fmt, $native{$fmt} ), direct_bytes( $fmt, $native{$fmt} ),
      "$fmt: the chat_f body equals the body chat_request builds from the same hashes" );
    is_deeply( chat_f_tools( $fmt, $native{$fmt} ), $native{$fmt}, "$fmt: every hash verbatim, in order" );
  }
};

my $obj = Langertha::Tool->new( name => 'obj', description => 'An object', input_schema => $schema );
my $mcp = { name => 'mcp', description => 'An MCP tool', inputSchema => $schema };
my $mcp_tool = Langertha::Tool->from_hash($mcp);

subtest 'a Langertha::Tool goes out in the wire shape of the engine' => sub {
  for my $fmt (qw( openai anthropic ollama responses )) {
    is_deeply( chat_f_tools( $fmt, [$obj] ), [ $obj->to($fmt) ], "$fmt: serialized by Tool->to" );
  }
  is_deeply( chat_f_tools( gemini => [$obj] ), [ { functionDeclarations => [ $obj->to('gemini') ] } ],
    'gemini: wrapped in one functionDeclarations entry' );
  # hermes: tools ride the prompt (chat_with_tools_f); chat_f leaves the list
  # alone, so the object goes out through TO_JSON. Pinned unchanged, not
  # endorsed -- a known gap, karr #231.
  is_deeply( chat_f_tools( hermes => [$obj] ), [ $obj->to_hash ],
    'hermes: list unchanged (known gap, karr #231)' );
};

subtest 'a function-tool hash in another shape is converted, per item' => sub {
  for my $fmt (qw( openai anthropic ollama responses )) {
    is_deeply( chat_f_tools( $fmt, [$mcp] ), [ $mcp_tool->to($fmt) ], "$fmt: an MCP hash is converted" );
  }
  is_deeply( chat_f_tools( gemini => [$mcp] ), [ { functionDeclarations => [ $mcp_tool->to('gemini') ] } ],
    'gemini: an MCP hash becomes a declaration' );
  my $canonical = { name => 'mcp', description => 'An MCP tool', input_schema => $schema };
  is_deeply( chat_f_tools( openai => [$canonical] ), [ $mcp_tool->to('openai') ],
    'openai: a canonical input_schema hash is converted' );
  my $nested = { type => 'function', function => { name => 'mcp', description => 'An MCP tool', parameters => $schema } };
  is_deeply( chat_f_tools( anthropic => [$nested] ), [ $mcp_tool->to('anthropic') ],
    'anthropic: an OpenAI-nested hash is converted' );
  # Unchanged, not endorsed -- a known gap, karr #231.
  is_deeply( chat_f_tools( hermes => [$mcp] ), [$mcp], 'hermes: list unchanged (known gap, karr #231)' );
};

subtest 'a converted hash keeps the extras its target wire takes' => sub {
  my $strict = { %$mcp, strict => JSON->true };
  is( chat_f_tools( openai => [$strict] )->[0]{function}{strict}, JSON->true,
    'openai: strict lands on function.strict' );
  my $cached = { %$mcp, cache_control => { type => 'ephemeral' } };
  is_deeply( chat_f_tools( anthropic => [$cached] )->[0]{cache_control}, { type => 'ephemeral' },
    'anthropic: cache_control is kept' );
  my $nested = { type => 'function', function => { name => 'n', parameters => { type => 'object', properties => {} }, strict => JSON->false } };
  is( chat_f_tools( anthropic => [$nested] )->[0]{strict}, JSON->false,
    'anthropic: an explicit function.strict wins over the schema guess' );
  my $decl = { name => 'decl', parameters => $schema, behavior => 'NON_BLOCKING' };
  is_deeply( chat_f_tools( gemini => [$decl] ), [ { functionDeclarations => [$decl] } ],
    'gemini: a bare declaration is not round-tripped, so its extra fields stay' );
};

subtest 'a Langertha::ServerTool: native on its wire, refused elsewhere' => sub {
  my $st = Langertha::ServerTool->new( wire => 'responses', spec => { type => 'web_search' } );
  is_deeply( chat_f_tools( responses => [$st] ), [ { type => 'web_search' } ], 'responses: its native hash' );
  for my $fmt (qw( openai anthropic gemini ollama hermes )) {
    my ( $engine, $mock ) = engine_for($fmt);
    ok( !eval { $engine->chat_f( messages => ['hi'], tools => [$st] )->get; 1 }, "$fmt: croaks" );
    like( $@, qr/does not supports\('server_tools'\)/, "$fmt: says why" );
    is( $mock->request_count, 0, "$fmt: nothing was sent" );
  }
};

subtest 'mixed lists keep the caller order' => sub {
  my $st = Langertha::ServerTool->new( wire => 'responses', spec => { type => 'code_interpreter', container => { type => 'auto' } } );
  my %mixed = (
    openai    => [ [ $native{openai}[0], $obj, $mcp, $native{openai}[1] ],
                   [ $native{openai}[0], $obj->to('openai'), $mcp_tool->to('openai'), $native{openai}[1] ] ],
    ollama    => [ [ $native{ollama}[0], $obj, $mcp ],
                   [ $native{ollama}[0], $obj->to('ollama'), $mcp_tool->to('ollama') ] ],
    anthropic => [ [ $native{anthropic}[0], $obj, $mcp, $native{anthropic}[1] ],
                   [ $native{anthropic}[0], $obj->to('anthropic'), $mcp_tool->to('anthropic'), $native{anthropic}[1] ] ],
    responses => [ [ $native{responses}[0], $obj, $mcp, $native{responses}[1], $st ],
                   [ $native{responses}[0], $obj->to('responses'), $mcp_tool->to('responses'),
                     $native{responses}[1], $st->to('responses') ] ],
    hermes    => [ [ $native{hermes}[0], $obj, $mcp ], [ $native{hermes}[0], $obj->to_hash, $mcp ] ],
  );
  for my $fmt ( sort keys %mixed ) {
    my ( $in, $want ) = @{ $mixed{$fmt} };
    is_deeply( chat_f_tools( $fmt, $in ), $want, "$fmt: every item in place" );
  }
  is_deeply( chat_f_tools( gemini => [ { google_search => {} }, $obj, $mcp ] ),
    [ { google_search => {} }, { functionDeclarations => [ $obj->to('gemini'), $mcp_tool->to('gemini') ] } ],
    'gemini: declarations grouped where the first one was, built-in in place' );
};

subtest 'gemini: one functionDeclarations entry (k221 review M4)' => sub {
  my $raw = $native{gemini}[1];
  my $raw_decl = $raw->{functionDeclarations}[0];
  is_deeply( chat_f_tools( gemini => [ $raw, { google_search => {} }, $obj ] ),
    [ { functionDeclarations => [ $raw_decl, $obj->to('gemini') ] }, { google_search => {} } ],
    'a raw functionDeclarations entry absorbs the converted declarations' );
  is_deeply( chat_f_tools( gemini => [ $obj, $raw ] ),
    [ { functionDeclarations => [ $obj->to('gemini'), $raw_decl ] } ],
    'declarations keep the caller order across the merge' );
  my $second = { functionDeclarations => [ { name => 'two' } ] };
  is_deeply( chat_f_tools( gemini => [ $raw, $second ] ),
    [ { functionDeclarations => [ $raw_decl, { name => 'two' } ] } ],
    'two raw functionDeclarations entries merge into the first' );
  my $combined = { functionDeclarations => [ { name => 'two' } ], codeExecution => {} };
  is_deeply( chat_f_tools( gemini => [ $raw, $combined ] ),
    [ { functionDeclarations => [ $raw_decl, { name => 'two' } ] }, { codeExecution => {} } ],
    'a later entry gives up its declarations and keeps its other fields' );

  # k227 review M1: the REST API reads function_declarations too (ADR 0018);
  # both spellings fold into the one entry, or Gemini gets two.
  my $snake = { function_declarations => [ { name => 'snake' } ] };
  is_deeply( chat_f_tools( gemini => [ $snake, $obj ] ),
    [ { functionDeclarations => [ { name => 'snake' }, $obj->to('gemini') ] } ],
    'a function_declarations entry absorbs the converted declarations' );
  is_deeply( chat_f_tools( gemini => [ $raw, { function_declarations => [ { name => 'two' } ], codeExecution => {} } ] ),
    [ { functionDeclarations => [ $raw_decl, { name => 'two' } ] }, { codeExecution => {} } ],
    'a later function_declarations entry merges into the first and keeps its other fields' );
};

subtest 'a Gemini declaration with parametersJsonSchema keeps its schema off Gemini (k227 review M2)' => sub {
  # Gemini declares a schema as parameters OR parametersJsonSchema (ADR 0018:
  # accept both). Read only as parameters, the other spelling went out on a
  # non-Gemini wire with an empty schema -- a tool whose arguments vanished.
  for my $key (qw( parametersJsonSchema parameters_json_schema )) {
    my $decl = { name => 'mcp', description => 'An MCP tool', $key => $schema };
    for my $fmt (qw( openai anthropic ollama )) {
      is_deeply( chat_f_tools( $fmt, [$decl] ), [ $mcp_tool->to($fmt) ], "$fmt: $key becomes the schema" );
    }
    is_deeply( chat_f_tools( gemini => [$decl] ), [ { functionDeclarations => [$decl] } ],
      "gemini: a $key declaration goes out verbatim" );
  }
};

done_testing;
