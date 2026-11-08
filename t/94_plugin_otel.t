#!/usr/bin/env perl
# ABSTRACT: Langertha::Plugin::OTel spans on a virtual engine's chat and tool loop: structure, content gating, sessions (no network)

use strict;
use warnings;

use Test2::Bundle::More;
use Path::Tiny;
use IO::Socket::INET;
use JSON::MaybeXS;

use lib path(__FILE__)->parent->child('lib')->stringify;

use Test::MockMCP;

use Langertha::Chat;
use Langertha::Content::Image;
use Langertha::Engine::Virtual;
use Langertha::Plugin::OTel;
use Langertha::Virtual::Rules qw( answer tool tools after error );

my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );

# Distinctive strings: with capture_content off none of them may appear
# anywhere in the serialized payload.
my %SENTINEL = (
  prompt => 'PROMPT-SENTINEL-7f3a',
  system => 'SYSTEM-SENTINEL-91bc',
  answer => 'ANSWER-SENTINEL-c0d2',
  args   => 'ARGS-SENTINEL-55e1',
  result => 'RESULT-SENTINEL-0a9f',
);

my $tool_calls_seen = 0;
my $mcp = Test::MockMCP->new( tools => [
  { name => 'lookup', description => 'Look something up',
    input_schema => { type => 'object', properties => { query => { type => 'string' } } },
    code => sub { my ( $self, $args ) = @_; $tool_calls_seen++; return $self->text_result( $SENTINEL{result} ) } },
  { name => 'broken', description => 'Always fails',
    input_schema => { type => 'object', properties => {} },
    code => sub { my ( $self ) = @_; return $self->text_result( 'it broke', 1 ) } },
] );

sub engine {
  my ( @extra ) = @_;
  return Langertha::Engine::Virtual->new(
    langfuse_enabled => 0,
    rules => [
      qr/\A\Q$SENTINEL{prompt}\E/ => sub {
        tool( lookup => { query => $SENTINEL{args} }, usage => { prompt_tokens => 12, completion_tokens => 5 } )
      },
      qr/\Atwo tools\z/ => sub {
        tools( [ [ lookup => { query => 'a' } ], [ lookup => { query => 'b' } ] ] )
      },
      qr/\Abreak\z/ => sub { tool( broken => {} ) },
      qr/\Aboom\z/  => sub { error( 500, 'upstream down' ) },
      after('lookup') => sub { answer( $SENTINEL{answer}, usage => { prompt_tokens => 20, completion_tokens => 2 } ) },
      after('broken') => sub { answer('recovered') },
    ],
    fallback => answer( $SENTINEL{answer}, usage => { prompt_tokens => 3, completion_tokens => 4 } ),
    @extra,
  );
}

# A port nothing listens on: bound, then closed again.
sub free_port {
  my $socket = IO::Socket::INET->new( Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0 ) or die $!;
  my $port = $socket->sockport;
  close $socket;
  return $port;
}

# A Chat with the plugin instantiated through the host's plugin spec, so the
# plugin's host is the Chat (its model / temperature overrides apply).
sub chat_with_otel {
  my ( %args ) = @_;
  my $plugin = delete $args{plugin} || {};
  my $chat = Langertha::Chat->new(
    engine      => $args{engine} || engine(),
    mcp_servers => [$mcp],
    plugins     => [ OTel => { endpoint => 'http://127.0.0.1:' . free_port() . '/v1/traces', headers => {}, %$plugin } ],
    %{ $args{chat} || {} },
  );
  my ($otel) = grep { $_->isa('Langertha::Plugin::OTel') } @{ $chat->plugin_instances };
  return ( $chat, $otel );
}

sub spans_of { my ($otel) = @_; return $json->decode( $otel->_otlp->to_json( $otel->_batch ) )->{resourceSpans}[0]{scopeSpans}[0]{spans} }

sub attrs_of {
  my ($span) = @_;
  return { map { $_->{key} => $_->{value} } @{ $span->{attributes} } };
}

sub sval { my ( $span, $key ) = @_; my $v = attrs_of($span)->{$key}; return $v ? $v->{stringValue} : undef }

subtest 'tool loop: spans, parents, names, kinds, one trace' => sub {
  my ( $chat, $otel ) = chat_with_otel();
  my $text = $chat->simple_chat_with_tools( $SENTINEL{prompt} );
  is_deeply( $text, $SENTINEL{answer}, 'the loop answered' );
  my @spans = @{ spans_of($otel) };
  is_deeply( scalar @spans, 3, 'two LLM calls and one tool call' );
  is_deeply( [ map { $_->{name} } @spans ], [ 'chat virtual', 'execute_tool lookup', 'chat virtual' ],
    'span names: "chat <model>", "execute_tool <name>"' );
  is_deeply( scalar( keys %{ { map { $_->{traceId} => 1 } @spans } } ), 1, 'one trace id across the conversation' );
  like( $spans[0]{traceId}, qr/\A[0-9a-f]{32}\z/, 'trace id shape' );
  is_deeply( [ map { $_->{kind} } @spans ], [ 3, 1, 3 ], 'CLIENT, INTERNAL, CLIENT' );
  my %ids = map { $_->{spanId} => 1 } @spans;
  is_deeply( scalar keys %ids, 3, 'distinct span ids' );
  ok( !exists $spans[0]{parentSpanId} && !exists $spans[2]{parentSpanId}, 'chat spans are roots (no synthetic root span)' );
  is_deeply( $spans[1]{parentSpanId}, $spans[0]{spanId}, 'tool span parent = the chat span that requested it' );
  ok( !exists $_->{status}, 'status unset on success' ) for @spans;
  ok( $_->{endTimeUnixNano} >= $_->{startTimeUnixNano}, 'end >= start' ) for @spans;
  ok( $spans[0]{endTimeUnixNano} <= $spans[2]{startTimeUnixNano}, 'chat spans do not overlap in time' );

  my $a0 = attrs_of( $spans[0] );
  is_deeply( $a0->{'gen_ai.operation.name'}, { stringValue => 'chat' }, 'operation chat' );
  is_deeply( $a0->{'gen_ai.provider.name'}, { stringValue => 'langertha.virtual' }, 'provider name' );
  is_deeply( $a0->{'gen_ai.request.model'}, { stringValue => 'virtual' }, 'request model' );
  is_deeply( $a0->{'gen_ai.response.model'}, { stringValue => 'virtual' }, 'response model' );
  like( $a0->{'gen_ai.response.id'}{stringValue}, qr/\Avirtual-\d+\z/, 'response id as string' );
  is_deeply( $a0->{'gen_ai.response.finish_reasons'}, { arrayValue => { values => [ { stringValue => 'tool_calls' } ] } },
    'finish_reasons is an array of the raw reason' );
  is_deeply( $a0->{'gen_ai.usage.input_tokens'}, { intValue => '12' }, 'input tokens' );
  is_deeply( $a0->{'gen_ai.usage.output_tokens'}, { intValue => '5' }, 'output tokens' );
  is_deeply( $a0->{'server.address'}, { stringValue => 'virtual.invalid' }, 'server.address' );
  is_deeply( $a0->{'server.port'}, { intValue => '80' }, 'server.port' );
  ok( !exists $a0->{'gen_ai.system'}, 'no deprecated gen_ai.system' );
  ok( !exists $a0->{'gen_ai.conversation.id'} && !exists $a0->{'session.id'}, 'no conversation id without session_id' );
  my $a2 = attrs_of( $spans[2] );
  is_deeply( $a2->{'gen_ai.response.finish_reasons'}, { arrayValue => { values => [ { stringValue => 'stop' } ] } }, 'second call stop' );
  is_deeply( $a2->{'gen_ai.usage.input_tokens'}, { intValue => '20' }, 'second call usage' );

  my $a1 = attrs_of( $spans[1] );
  is_deeply( $a1->{'gen_ai.operation.name'}, { stringValue => 'execute_tool' }, 'tool operation' );
  is_deeply( $a1->{'gen_ai.tool.name'}, { stringValue => 'lookup' }, 'gen_ai.tool.name' );
  is_deeply( $a1->{'gen_ai.tool.type'}, { stringValue => 'function' }, 'gen_ai.tool.type' );
  ok( length $a1->{'gen_ai.tool.call.id'}{stringValue}, 'gen_ai.tool.call.id from the matched request' );
  ok( !exists $a1->{'error.type'}, 'no error type on success' );
};

subtest 'two tool calls in one turn: both children of the requesting chat span, own call ids' => sub {
  my ( $chat, $otel ) = chat_with_otel( engine => engine( default_usage => { prompt_tokens => 1, completion_tokens => 1 } ) );
  $chat->simple_chat_with_tools('two tools');
  my @spans = @{ spans_of($otel) };
  my @tool = grep { $_->{name} eq 'execute_tool lookup' } @spans;
  is_deeply( scalar @tool, 2, 'two tool spans' );
  is_deeply( [ map { $_->{parentSpanId} } @tool ], [ ( $spans[0]{spanId} ) x 2 ], 'both parented to the first chat span' );
  my @call_ids = map { attrs_of($_)->{'gen_ai.tool.call.id'}{stringValue} } @tool;
  ok( ( grep { defined && length } @call_ids ) == 2, 'both have a call id' );
  isnt( $call_ids[0], $call_ids[1], 'call ids differ (matched by name and arguments)' );
  is_deeply( scalar( keys %{ { map { $_->{traceId} => 1 } @spans } } ), 1, 'still one trace' );
};

subtest 'isError tool result: error status and error.type' => sub {
  my ( $chat, $otel ) = chat_with_otel();
  $chat->simple_chat_with_tools('break');
  my ($tool) = grep { $_->{name} eq 'execute_tool broken' } @{ spans_of($otel) };
  ok( $tool, 'tool span exists' );
  is_deeply( $tool->{status}, { code => 2 }, 'status ERROR (2), no message' );
  is_deeply( attrs_of($tool)->{'error.type'}, { stringValue => '_OTHER' }, 'error.type _OTHER' );
};

subtest 'a failed LLM call is an error span and does not disturb the next one' => sub {
  my ( $chat, $otel ) = chat_with_otel();
  ok( !eval { $chat->simple_chat('boom'); 1 }, 'the failing call still dies for the caller' );
  is_deeply( scalar @{ $otel->_batch }, 1, 'one span for the failed call' );
  my $text = eval { $chat->simple_chat('fine') };
  is_deeply( $text, $SENTINEL{answer}, 'next call works' );
  my @spans = @{ spans_of($otel) };
  is_deeply( scalar @spans, 2, 'two spans: the failed call and the next one' );
  is_deeply( $spans[0]{status}, { code => 2 }, 'the failed call has status ERROR' );
  ok( !exists $spans[1]{status}, 'the next one is unset' );
};

subtest 'plain chat, Chat overrides, provider_name override' => sub {
  my ( $chat, $otel ) = chat_with_otel(
    chat   => { model => 'my-model-1', temperature => 0.4 },
    plugin => { provider_name => 'my.provider' },
  );
  $chat->simple_chat('hello');
  my ($span) = @{ spans_of($otel) };
  my $a = attrs_of($span);
  is_deeply( $span->{name}, 'chat my-model-1', 'span name uses the Chat model override' );
  is_deeply( $a->{'gen_ai.request.model'}, { stringValue => 'my-model-1' }, 'request model = override' );
  is_deeply( $a->{'gen_ai.request.temperature'}, { doubleValue => 0.4 }, 'temperature override as doubleValue' );
  is_deeply( $a->{'gen_ai.provider.name'}, { stringValue => 'my.provider' }, 'provider_name override' );
  is_deeply( $a->{'gen_ai.usage.input_tokens'}, { intValue => '3' }, 'usage from the answer' );
};

subtest 'reset_trace starts a new trace; spans are kept' => sub {
  my ( $chat, $otel ) = chat_with_otel();
  $chat->simple_chat('one');
  $chat->simple_chat('two');
  $otel->reset_trace;
  $chat->simple_chat('three');
  my @spans = @{ spans_of($otel) };
  is_deeply( scalar @spans, 3, 'reset_trace keeps unflushed spans' );
  is_deeply( $spans[0]{traceId}, $spans[1]{traceId}, 'same trace before the reset' );
  isnt( $spans[2]{traceId}, $spans[0]{traceId}, 'new trace id after reset_trace' );
  like( $spans[2]{traceId}, qr/\A[0-9a-f]{32}\z/, 'new id shape' );

  # a tool span after a reset does not point at a chat span of the old trace
  my ( $chat2, $otel2 ) = chat_with_otel();
  $chat2->simple_chat_with_tools( $SENTINEL{prompt} );
  $otel2->reset_trace;
  $chat2->simple_chat_with_tools( $SENTINEL{prompt} );
  my @s2 = @{ spans_of($otel2) };
  my @old = @s2[ 0 .. 2 ];
  my @new = @s2[ 3 .. 5 ];
  is_deeply( scalar( keys %{ { map { $_->{traceId} => 1 } @new } } ), 1, 'second conversation: one trace' );
  isnt( $new[0]{traceId}, $old[0]{traceId}, '... a different one' );
  is_deeply( $new[1]{parentSpanId}, $new[0]{spanId}, '... with its own parent link' );
};

subtest 'session_id: gen_ai.conversation.id and session.id on every span' => sub {
  my ( $chat, $otel ) = chat_with_otel( plugin => { session_id => 'conv-42' } );
  $chat->simple_chat_with_tools( $SENTINEL{prompt} );
  my @spans = @{ spans_of($otel) };
  is_deeply( scalar @spans, 3, 'three spans' );
  for my $span (@spans) {
    my $a = attrs_of($span);
    is_deeply( $a->{'gen_ai.conversation.id'}, { stringValue => 'conv-42' }, "$span->{name}: gen_ai.conversation.id" );
    is_deeply( $a->{'session.id'}, { stringValue => 'conv-42' }, "$span->{name}: session.id" );
  }
  my ( $plain_chat, $plain ) = chat_with_otel();
  $plain_chat->simple_chat_with_tools( $SENTINEL{prompt} );
  my $body = $plain->_otlp->to_json( $plain->_batch );
  unlike( $body, qr/conversation\.id|session\.id/, 'never invents a conversation id' );
};

subtest 'enabled => 0 records nothing' => sub {
  my ( $chat, $otel ) = chat_with_otel( plugin => { enabled => 0 } );
  my $text = $chat->simple_chat_with_tools( $SENTINEL{prompt} );
  is_deeply( $text, $SENTINEL{answer}, 'the call itself works' );
  is_deeply( scalar @{ $otel->_batch }, 0, 'no spans' );
  is_deeply( $otel->flush, undef, 'flush does nothing' );
};

subtest 'max_batch drops the oldest and warns once' => sub {
  my ( $chat, $otel ) = chat_with_otel( plugin => { max_batch => 2 } );
  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, $_[0] };
  $chat->simple_chat("call $_") for 1 .. 4;
  is_deeply( scalar @{ $otel->_batch }, 2, 'batch capped' );
  is_deeply( scalar @warnings, 1, 'one warning only' );
  like( $warnings[0], qr/max_batch/, 'warning names max_batch' );
  my @spans = @{ spans_of($otel) };
  ok( $spans[0]{startTimeUnixNano} <= $spans[1]{startTimeUnixNano}, 'the newest spans are kept in order' );
};

subtest 'capture_content OFF (default): no content anywhere in the payload' => sub {
  my ( $chat, $otel ) = chat_with_otel( chat => { system_prompt => $SENTINEL{system} } );
  ok( !$otel->capture_content, 'default is off' );
  my $text = $chat->simple_chat_with_tools( $SENTINEL{prompt} );
  is_deeply( $text, $SENTINEL{answer}, 'the loop ran and returned the answer' );
  ok( $tool_calls_seen, 'the tool really ran' );
  my $body = $otel->_otlp->to_json( $otel->_batch );
  for my $what ( sort keys %SENTINEL ) {
    unlike( $body, qr/\Q$SENTINEL{$what}\E/, "no $what text in the payload" );
  }
  unlike( $body, qr/gen_ai\.(?:input|output)\.messages|system_instructions|tool\.call\.(?:arguments|result)/,
    'no content attribute keys at all' );
  unlike( $body, qr/Look something up/, 'no tool description' );
  # also in a plain (non-tool) chat and with an error in a tool
  my ( $c2, $o2 ) = chat_with_otel( chat => { system_prompt => $SENTINEL{system} } );
  $c2->simple_chat( $SENTINEL{prompt} . ' plain' );
  unlike( $o2->_otlp->to_json( $o2->_batch ), qr/SENTINEL/, 'plain chat: no sentinel text either' );
};

subtest 'capture_content ON: messages as JSON-string attributes' => sub {
  my ( $chat, $otel ) = chat_with_otel(
    chat   => { system_prompt => $SENTINEL{system} },
    plugin => { capture_content => 1 },
  );
  $chat->simple_chat_with_tools( $SENTINEL{prompt} );
  my @spans = @{ spans_of($otel) };

  my $first = attrs_of( $spans[0] );
  ok( exists $first->{'gen_ai.input.messages'}{stringValue}, 'input messages is a stringValue (JSON text)' );
  my $input = $json->decode( $first->{'gen_ai.input.messages'}{stringValue} );
  is_deeply( [ map { $_->{role} } @$input ], [ 'system', 'user' ], 'system prompt and user message, roles' );
  is_deeply( $input->[0]{parts}, [ { type => 'text', content => $SENTINEL{system} } ], 'system prompt as text part' );
  is_deeply( $input->[1]{parts}, [ { type => 'text', content => $SENTINEL{prompt} } ], 'user prompt as text part' );

  my $output = $json->decode( $first->{'gen_ai.output.messages'}{stringValue} );
  is_deeply( scalar @$output, 1, 'one output message' );
  is_deeply( $output->[0]{role}, 'assistant', 'assistant role' );
  is_deeply( $output->[0]{finish_reason}, 'tool_call', 'finish reason mapped to the conventions enum' );
  my ($call) = grep { $_->{type} eq 'tool_call' } @{ $output->[0]{parts} };
  is_deeply( $call->{name}, 'lookup', 'tool call name' );
  is_deeply( $call->{arguments}, { query => $SENTINEL{args} }, 'tool call arguments as structured data' );
  ok( length $call->{id}, 'tool call id' );

  my $tool = attrs_of( $spans[1] );
  is_deeply( $json->decode( $tool->{'gen_ai.tool.call.arguments'}{stringValue} ), { query => $SENTINEL{args} },
    'gen_ai.tool.call.arguments' );
  like( $tool->{'gen_ai.tool.call.result'}{stringValue}, qr/\Q$SENTINEL{result}\E/, 'gen_ai.tool.call.result' );

  my $last = attrs_of( $spans[2] );
  my $input2 = $json->decode( $last->{'gen_ai.input.messages'}{stringValue} );
  my @parts = map { @{ $_->{parts} } } @$input2;
  ok( ( grep { $_->{type} eq 'tool_call' && $_->{name} eq 'lookup' } @parts ), 'second call input carries the tool call' );
  my ($response) = grep { $_->{type} eq 'tool_call_response' } @parts;
  is_deeply( $response->{response}, $SENTINEL{result}, 'second call input carries the tool result' );
  is_deeply( $response->{id}, $call->{id}, 'tool_call_response id matches the tool_call id' );
  my $output2 = $json->decode( $last->{'gen_ai.output.messages'}{stringValue} );
  is_deeply( $output2->[0]{parts}, [ { type => 'text', content => $SENTINEL{answer} } ], 'answer text captured' );
  is_deeply( $output2->[0]{finish_reason}, 'stop', 'stop' );
};

subtest 'capture_content ON: image bytes never leave' => sub {
  my $b64 = 'QUJD' x 400;   # "ABC" repeated, long enough to be recognized as inline data
  my ( $chat, $otel ) = chat_with_otel( plugin => { capture_content => 1 } );
  $chat->simple_chat( {
    role    => 'user',
    content => [ 'What is this?', Langertha::Content::Image->from_base64( $b64, media_type => 'image/png' ) ],
  } );
  my $body = $otel->_otlp->to_json( $otel->_batch );
  like( $body, qr/What is this\?/, 'the text part is captured' );
  unlike( $body, qr/QUJDQUJDQUJD/, 'the base64 image data is not in the payload' );

  my ( $chat2, $otel2 ) = chat_with_otel( plugin => { capture_content => 1 } );
  my $data_url = "data:image/png;base64,$b64";
  $chat2->simple_chat( {
    role    => 'user',
    content => [ { type => 'text', text => 'inline' }, { type => 'image_url', image_url => { url => $data_url } } ],
  } );
  my $body2 = $otel2->_otlp->to_json( $otel2->_batch );
  unlike( $body2, qr/QUJDQUJDQUJD/, 'an inline data: URL image is stripped as well' );
  like( $body2, qr/bytes omitted/, 'and replaced by its size' );
};

subtest 'undef tool name: one plain execute_tool span, no call id, no warnings' => sub {
  my ( $chat, $otel ) = chat_with_otel();
  my @warnings;
  my $result;
  {
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my ( $name, $input ) = $otel->plugin_before_tool_call( undef, { a => 1 } )->get;
    ok( !defined $name, 'before_tool_call hands the undef name back' );
    $result = $otel->plugin_after_tool_call( undef, { a => 1 }, 'out' )->get;
  }
  is( $result, 'out', 'after_tool_call returns the result' );
  is_deeply( \@warnings, [], 'no warnings' );
  my @spans = @{ spans_of($otel) };
  is( scalar @spans, 1, 'exactly one span' );
  is( $spans[0]{name}, 'execute_tool', 'named execute_tool, no trailing name' );
  ok( !exists attrs_of( $spans[0] )->{'gen_ai.tool.call.id'}, 'no gen_ai.tool.call.id' );
};

done_testing;
