#!/usr/bin/env perl
# ABSTRACT: Perplexity Agent API client function tools: Role::Tools, no tool_choice, echo filter (k213)

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;
use Future;

use lib 't/lib';
use Test::MockAsyncHTTP;

use Langertha::Engine::Perplexity;
use Langertha::Engine::OpenAIResponses;

# karr k213 / ADR 0020 (k213 Update), ADR 0005: the Agent API (POST /v1/agent)
# takes client-executed type:function tools. The model answers with a top-level
# function_call output item; the client sends back function_call_output items by
# call_id. Engine::Perplexity said "NO tool calling" -- stale since the move to
# /v1/agent (k139). What has to hold, and why:
#
#   - Perplexity composes Role::Tools (tools_native, the 'responses' tool wire),
#     so chat_f and chat_with_tools_f send the tools and read the calls back.
#   - The Agent request schema has NO tool_choice and NO parallel_tool_calls,
#     so every tool_choice_* flag and parallel_tool_use are cleared and neither
#     field ever reaches the wire. With tool_choice_named cleared, the ADR 0005
#     direction-1 rewrite (forced tool -> json_schema + synthetic ToolCall) still
#     fires: Perplexity stays its exemplar.
#   - The Agent input is a closed oneOf: message | function_call |
#     function_call_output, message parts only input_text / input_image. The
#     plain Responses echo replays every output[] item, which on a preset turn
#     includes search_results / fetch_url_results / mcp_* items and an assistant
#     message whose parts are output_text -- all off-schema as input. The
#     ResponsesCompatible hook _responses_echo_item filters them on Perplexity;
#     OpenAIResponses keeps the verbatim echo.
#
# No Perplexity function-call capture exists (a live one needs the maintainer's
# OK). Every payload below is built from the documented shapes: the OpenAPI for
# POST /v1/agent and docs.perplexity.ai/docs/agent-api/tools/custom-functions,
# fetched 2026-09-25 by the llm-advisor (see karr k213). Not live-verified.

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

sub ppx { Langertha::Engine::Perplexity->new( api_key => 'test-key', model => 'sonar', @_ ) }
sub body_of { $json->decode( $_[0]->content ) }

my $mcp_tool = {
    name        => 'get_weather',
    description => 'Weather for a city',
    inputSchema => { type => 'object', properties => { city => { type => 'string' } },
                     required => ['city'] },
};

# Documented function_call output item (custom-functions docs): top-level,
# fc_ id, call_id, JSON-string arguments, status, optional thought_signature.
my $fc_item = {
    type => 'function_call', id => 'fc_001', call_id => 'call_abc',
    name => 'get_weather', arguments => '{"city":"Berlin"}', status => 'completed',
    thought_signature => 'sig-xyz',
};

# A preset turn: presets merge their web_search with the caller's function tool,
# so one turn can carry search results, a message preamble and the call.
my $turn1 = {
    id => 'resp_1', object => 'response', model => 'openai/gpt-5.6-luna', status => 'completed',
    output => [
        { type => 'search_results', results => [ { id => 1, url => 'https://w.example/berlin', title => 'Berlin weather' } ] },
        { type => 'fetch_url_results', contents => [ { url => 'https://w.example/berlin', text => '...' } ] },
        { type => 'message', id => 'msg_1', role => 'assistant', status => 'completed',
          content => [ { type => 'output_text', text => 'Let me check.', annotations => [] } ] },
        $fc_item,
    ],
    usage => { input_tokens => 10, output_tokens => 5, total_tokens => 15 },
};
my $turn2 = {
    id => 'resp_2', object => 'response', model => 'openai/gpt-5.6-luna', status => 'completed',
    output => [ { type => 'message', id => 'msg_2', role => 'assistant', status => 'completed',
        content => [ { type => 'output_text', text => 'Sunny, 21C.', annotations => [] } ] } ],
    usage => { input_tokens => 20, output_tokens => 4, total_tokens => 24 },
};

subtest 'composition and capabilities' => sub {
    my $engine = ppx();
    ok( $engine->does('Langertha::Role::Tools'), 'Perplexity composes Role::Tools' );
    is( $engine->tool_wire_format, 'responses', 'tool wire is responses (ResponsesCompatible builder wins)' );
    my $caps = $engine->engine_capabilities;
    ok( $caps->{tools_native}, 'tools_native' );
    ok( !$caps->{$_}, "$_ cleared (no tool_choice in the Agent schema)" )
        for qw( tool_choice_auto tool_choice_any tool_choice_none tool_choice_named );
    ok( !$caps->{parallel_tool_use}, 'parallel_tool_use cleared (no parallel_tool_calls field)' );
    ok( !$caps->{server_tools}, 'no server_tools (built-ins are k206 Phase 2)' );
    ok( $caps->{response_format_json_schema}, 'json_schema stays (direction-1 target)' );
};

subtest 'request: flat function tools, never tool_choice or parallel_tool_calls' => sub {
    for my $builder (qw( chat_request chat_stream_request )) {
        my @warns;
        local $SIG{__WARN__} = sub { push @warns, $_[0] };
        my $body = body_of( ppx()->$builder( [ { role => 'user', content => 'weather?' } ],
            tools => [$mcp_tool], tool_choice => 'auto',
            controls => { parallel_tool_use => 1 } ) );
        is_deeply( $body->{tools}, [ { type => 'function', name => 'get_weather',
            description => 'Weather for a city', parameters => $mcp_tool->{inputSchema} } ],
            "$builder: MCP tool formatted to the flat function shape" );
        ok( !exists $body->{tool_choice}, "$builder: tool_choice auto not sent" );
        ok( !exists $body->{parallel_tool_calls}, "$builder: parallel_tool_calls not sent" );
        ok( !@warns, "$builder: dropping auto is silent (it is the default)" ) or diag @warns;

        @warns = ();
        $body = body_of( ppx()->$builder( [ { role => 'user', content => 'weather?' } ],
            tools => [$mcp_tool], tool_choice => { type => 'tool', name => 'get_weather' } ) );
        ok( !exists $body->{tool_choice}, "$builder: forced tool_choice not sent" );
        ok( ( grep { /dropping tool_choice/ } @warns ), "$builder: dropping a forced choice carps" );
    }
    # OpenAIResponses supports tool_choice: unchanged, still sent.
    my $body = body_of( Langertha::Engine::OpenAIResponses->new( api_key => 'k', model => 'gpt-5.6-luna' )
        ->chat_request( [ { role => 'user', content => 'x' } ], tools => [$mcp_tool], tool_choice => 'auto' ) );
    is( $body->{tool_choice}, 'auto', 'OpenAIResponses still sends tool_choice' );
};

subtest 'chat_f: native tools, function_call lands on Response.tool_calls' => sub {
    my $mock = Test::MockAsyncHTTP->new( responses => [ Test::MockAsyncHTTP->mock_json_response($turn1) ] );
    my $resp = ppx( _async_http => $mock )->chat_f(
        messages => [ { role => 'user', content => 'weather in Berlin?' } ],
        tools    => [$mcp_tool],
    )->get;
    my ($sent) = $mock->requests;
    my $body = body_of($sent);
    is( $body->{tools}[0]{name}, 'get_weather', 'tool on the wire' );
    ok( !exists $body->{response_format}, 'not rewritten: no forced choice' );
    ok( !exists $body->{tool_choice}, 'no tool_choice' );
    my $tc = $resp->tool_call('get_weather');
    ok( $tc, 'ToolCall present' );
    ok( !$tc->synthetic, 'native, not synthetic' );
    is( $tc->id, 'call_abc', 'id is the call_id' );
    is_deeply( $tc->arguments, { city => 'Berlin' }, 'JSON-string arguments decoded' );
    is( $resp->finish_reason, 'tool_calls', 'finish_reason tool_calls' );
    is( scalar @{ $resp->citations // [] }, 1, 'search_results still lift to citations' );
};

subtest 'ADR 0005 direction 1 still fires with Role::Tools composed' => sub {
    my $mock = Test::MockAsyncHTTP->new( responses => [ Test::MockAsyncHTTP->mock_json_response( {
        id => 'resp_3', model => 'sonar', status => 'completed',
        output => [ { type => 'message', status => 'completed',
            content => [ { type => 'output_text', text => '{"city":"Berlin"}' } ] } ],
        usage => { input_tokens => 1, output_tokens => 1, total_tokens => 2 },
    } ) ] );
    my $engine = ppx( _async_http => $mock );
    ok( $engine->supports('tools_native') && !$engine->supports('tool_choice_named'),
        'precondition: tools yes, named choice no' );
    my $resp = $engine->chat_f(
        messages    => [ { role => 'user', content => 'Which city?' } ],
        tools       => [$mcp_tool],
        tool_choice => { type => 'tool', name => 'get_weather' },
    )->get;
    my $body = body_of( ( $mock->requests )[0] );
    ok( !exists $body->{tools} && !exists $body->{tool_choice}, 'tools and tool_choice rewritten away' );
    is( $body->{response_format}{type}, 'json_schema', 'top-level response_format json_schema' );
    my $tc = $resp->tool_call('get_weather');
    ok( $tc && $tc->synthetic, 'synthetic ToolCall' );
    is_deeply( $tc && $tc->arguments, { city => 'Berlin' }, 'structured args' );
};

sub assert_agent_input {
    my ( $input, $label ) = @_;
    my %allowed = map { $_ => 1 } qw( message function_call function_call_output );
    for my $item (@$input) {
        ok( $allowed{ $item->{type} // '' }, "$label: input item type '" . ( $item->{type} // 'undef' ) . "' is on the Agent schema" );
        next unless ( $item->{type} // '' ) eq 'message' && ref $item->{content} eq 'ARRAY';
        for my $part ( @{ $item->{content} } ) {
            like( $part->{type} // '', qr/\Ainput_(?:text|image)\z/, "$label: message part $part->{type}" );
        }
    }
}

subtest 'echo filter: format_tool_results on Perplexity' => sub {
    my $engine  = ppx();
    my @results = ( { tool_call => $fc_item,
        result => { content => [ { type => 'text', text => 'Sunny, 21C' } ] } } );
    my @echo = $engine->format_tool_results( $turn1, \@results );
    is_deeply( \@echo, [
        { type => 'message', role => 'assistant', content => 'Let me check.' },
        $fc_item,
        { type => 'function_call_output', call_id => 'call_abc',
          output => $json->encode( [ { type => 'text', text => 'Sunny, 21C' } ] ) },
    ], 'search/fetch results dropped, message flattened to text, function_call kept verbatim (thought_signature too)' );

    # mcp_* items and an empty preamble are dropped; a legacy nested call is hoisted then kept.
    my $data = { output => [
        { type => 'mcp_list_tools', server_label => 's', tools => [] },
        { type => 'mcp_call', id => 'mcp_1', name => 'x', arguments => '{}', output => 'y' },
        { type => 'finance_results', results => [] },
        { type => 'message', role => 'assistant', status => 'completed', content => [ $fc_item ] },
    ] };
    @echo = $engine->format_tool_results( $data, \@results );
    is_deeply( [ map { $_->{type} } @echo ], [qw( function_call function_call_output )],
        'mcp_* / *_results dropped, empty message dropped, nested call hoisted' );

    # OpenAIResponses keeps the verbatim echo (default hook passes through).
    my @verbatim = Langertha::Engine::OpenAIResponses->new( api_key => 'k' )
        ->format_tool_results( $turn1, \@results );
    is( scalar @verbatim, 5, 'OpenAIResponses echoes all four output items plus the result' );
};

{
    package K213::MCP;
    sub new { bless { calls => [] }, shift }
    sub list_tools { Future->done( [$mcp_tool] ) }
    sub call_tool {
        my ( $self, $name, $input ) = @_;
        push @{ $self->{calls} }, [ $name, $input ];
        return Future->done( { content => [ { type => 'text', text => 'Sunny, 21C' } ] } );
    }
}

subtest 'chat_with_tools_f end to end (mocked HTTP)' => sub {
    my $mcp  = K213::MCP->new;
    my $mock = Test::MockAsyncHTTP->new( responses => [
        Test::MockAsyncHTTP->mock_json_response($turn1),
        Test::MockAsyncHTTP->mock_json_response($turn2),
    ] );
    my $engine = ppx( _async_http => $mock, mcp_servers => [$mcp] );
    my $text = $engine->chat_with_tools_f('Weather in Berlin?')->get;
    is( $text, 'Sunny, 21C.', 'final text after one tool round' );
    is_deeply( $mcp->{calls}, [ [ get_weather => { city => 'Berlin' } ] ], 'tool executed once with decoded args' );
    is( $mock->request_count, 2, 'two Agent requests' );

    my ( $r1, $r2 ) = map { body_of($_) } $mock->requests;
    for my $pair ( [ first => $r1 ], [ second => $r2 ] ) {
        my ( $label, $body ) = @$pair;
        is( $body->{preset}, 'fast', "$label: preset" );
        is( $body->{tools}[0]{type}, 'function', "$label: function tool sent" );
        ok( !exists $body->{tool_choice} && !exists $body->{parallel_tool_calls},
            "$label: no tool_choice / parallel_tool_calls" );
        assert_agent_input( $body->{input}, $label );
    }
    is_deeply( [ map { $_->{type} } @{ $r2->{input} } ],
        [qw( message message function_call function_call_output )],
        'second turn: user, assistant preamble, the call, its output' );
    is( $r2->{input}[1]{content}, 'Let me check.', 'assistant preamble echoed as text' );
    is( $r2->{input}[2]{thought_signature}, 'sig-xyz', 'thought_signature kept on the echoed call' );
    is( $r2->{input}[3]{call_id}, $r2->{input}[2]{call_id}, 'output answers the call by call_id' );
};

done_testing;
