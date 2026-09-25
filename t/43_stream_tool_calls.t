#!/usr/bin/env perl
# ABSTRACT: streamed tool calls arrive as the same ToolCall objects the non-streaming reply yields, on every dialect
use strict;
use warnings;

use Test2::Bundle::More;
use FindBin;
use lib "$FindBin::Bin/lib";

use HTTP::Response;
use JSON::MaybeXS;
use LWP::UserAgent;
use Path::Tiny;

use Langertha::Engine::AKIOpenAI;
use Langertha::Engine::AKIAnthropic;
use Langertha::Engine::OpenAI;
use Langertha::Engine::Anthropic;
use Langertha::Engine::Gemini;
use Langertha::Engine::Ollama;
use Langertha::Request::SyncHTTP;
use Langertha::Tool;

# karr k221: the Chat-Completions, Anthropic, Gemini and Ollama-native stream
# parsers read only text and thinking, so a streamed tool call was dropped on
# the floor and chat_stream_realtime_f ended as a silent, empty success -- a
# lost call quietly ends an agent loop. ADR 0003: Response.tool_calls is the one
# tool-call shape, so a stream must hand back the SAME Langertha::ToolCall the
# non-streaming reply of the same response produces, exactly once, built by
# ToolCall->extract (never by hand), and aggregate_tool_calls must find it.
#
# Source of truth for each finished call is a non-streaming reply read by
# chat_response: the verbatim AKI.IO captures (t/data/akiopenai_*,
# t/data/akianthropic_*) and the Ollama capture. No Gemini tool-call capture
# exists, so its reply follows the generateContent reference. The STREAMS are
# doc-derived, not captured: the event shapes follow each provider's streaming
# reference -- OpenAI Chat Completions chunk objects (delta.tool_calls with
# index-keyed function.arguments fragments), Anthropic Messages streaming
# (content_block_start tool_use + input_json_delta partial_json +
# content_block_stop), Gemini streamGenerateContent (whole functionCall parts)
# and Ollama /api/chat streaming (whole message.tool_calls) -- with the payload
# values taken from the capture, so fragments concatenate to its arguments.

my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );

sub reply_calls {
  my ( $engine, $file_or_data ) = @_;
  my $body = ref $file_or_data ? $json->encode($file_or_data) : path($file_or_data)->slurp_raw;
  my $res = HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'application/json' ], $body );
  return [ map { $_->to_hash } @{ $engine->chat_response($res)->tool_calls // [] } ];
}

sub hashes { [ map { $_->to_hash } @{ $_[0] } ] }
sub sse    { join '', map { 'data: ' . $json->encode($_) . "\n\n" } @_ }
sub sse_ev { join '', map { "event: $_->{type}\ndata: " . $json->encode($_) . "\n\n" } @_ }
sub ndjson { join '', map { $json->encode($_) . "\n" } @_ }

# ---------------------------------------------------------------------------
# OpenAI Chat Completions: fragments assembled per index, delivered on the
# chunk that carries finish_reason.
# ---------------------------------------------------------------------------

my $oa_capture = $json->decode( path('t/data/akiopenai_tool_call_response.json')->slurp_raw );
my $oa_call    = $oa_capture->{choices}[0]{message}{tool_calls}[0];

sub openai_stream_events {
  my (%opt) = @_;
  my %base = ( id => $oa_capture->{id}, object => 'chat.completion.chunk',
    created => $oa_capture->{created}, model => $oa_capture->{model} );
  my $choice = sub { +{ %base, choices => [ { index => 0, @_ } ] } };
  return (
    $choice->( delta => { role => 'assistant', content => undef, tool_calls => [
      { index => 0, id => $oa_call->{id}, type => 'function',
        function => { name => 'add', arguments => '' } } ] }, finish_reason => undef ),
    $choice->( delta => { tool_calls => [ { index => 0, function => { arguments => '{"a": 7' } } ] },
      finish_reason => undef ),
    $choice->( delta => { tool_calls => [ { index => 0, function => { arguments => ', "b": 15}' } } ] },
      finish_reason => undef ),
    ( $opt{truncated} ? () : $choice->( delta => {}, finish_reason => $opt{finish} // 'stop' ) ),
  );
}

subtest 'OpenAI: one call, parity with the AKI.IO non-streaming capture' => sub {
  my $engine = Langertha::Engine::AKIOpenAI->new( api_key => 'k', model => 'llama3-chat-8b' );
  my $chunks = $engine->process_stream_data( sse( openai_stream_events() ) . "data: [DONE]\n\n" );
  my $tcs    = $engine->aggregate_tool_calls($chunks);

  is_deeply( hashes($tcs), reply_calls( $engine, 't/data/akiopenai_tool_call_response.json' ),
    'the streamed call equals the one chat_response reads off the capture' );
  is( scalar @$tcs, 1, 'delivered exactly once' );
  isa_ok( $tcs->[0], 'Langertha::ToolCall' );
  is_deeply( $tcs->[0]->arguments, { a => 7, b => 15 }, 'arguments assembled from the fragments' );
  ok( $chunks->[-1]->has_tool_calls, 'the call rides the finish_reason chunk' );
  ok( !( grep { $_->has_tool_calls } @$chunks[ 0 .. $#$chunks - 1 ] ), 'and no fragment chunk' );
  is( $chunks->[-1]->finish_reason, 'stop', 'finish_reason passed through as the reply has it' );
};

subtest 'OpenAI: parallel calls, fragments interleaved by index' => sub {
  my $engine = Langertha::Engine::OpenAI->new( api_key => 'k', model => 'gpt-4o-mini' );
  my $c = sub { +{ id => 'chatcmpl-1', model => 'gpt-4o-mini', choices => [ { index => 0, @_ } ] } };
  my $body = sse(
    $c->( delta => { role => 'assistant', tool_calls => [
      { index => 0, id => 'call_a', type => 'function', function => { name => 'get_weather', arguments => '' } } ] } ),
    $c->( delta => { tool_calls => [ { index => 0, function => { arguments => '{"city":' } } ] } ),
    $c->( delta => { tool_calls => [
      { index => 1, id => 'call_b', type => 'function', function => { name => 'get_time', arguments => '' } } ] } ),
    $c->( delta => { tool_calls => [ { index => 1, function => { arguments => '{"tz":"CET"}' } } ] } ),
    $c->( delta => { tool_calls => [ { index => 0, function => { arguments => '"Paris"}' } } ] } ),
    $c->( delta => {}, finish_reason => 'tool_calls' ),
  );
  my $reply = reply_calls( $engine, { id => 'chatcmpl-1', model => 'gpt-4o-mini', choices => [ {
    index => 0, finish_reason => 'tool_calls', message => { role => 'assistant', content => undef, tool_calls => [
      { id => 'call_a', type => 'function', function => { name => 'get_weather', arguments => '{"city":"Paris"}' } },
      { id => 'call_b', type => 'function', function => { name => 'get_time',    arguments => '{"tz":"CET"}' } },
    ] } } ] } );

  for my $path ( 'sync', 'buffer' ) {
    my $chunks;
    if ( $path eq 'sync' ) { $chunks = $engine->process_stream_data($body) }
    else {
      my $buffer = $body;
      $chunks = $engine->_process_stream_buffer( \$buffer, 'sse', 1, {} );
    }
    is_deeply( hashes( $engine->aggregate_tool_calls($chunks) ), $reply,
      "$path: both calls, in index order, equal to the non-streaming reply" );
    is( $chunks->[-1]->finish_reason, 'tool_calls', "$path: finish_reason tool_calls kept" );
  }
};

subtest 'OpenAI: stream state is per stream' => sub {
  my $engine = Langertha::Engine::AKIOpenAI->new( api_key => 'k', model => 'llama3-chat-8b' );

  # Two streams interleaved on one engine (what two concurrent
  # chat_stream_realtime_f calls do): each keeps its own fragments.
  my @events = openai_stream_events();
  my ( %one, %two );
  my ( @one, @two );
  for my $event (@events) {
    for ( [ \%one, \@one ], [ \%two, \@two ] ) {
      my ( $state, $out ) = @$_;
      my $buffer = sse($event);
      push @$out, @{ $engine->_process_stream_buffer( \$buffer, 'sse', 0, $state ) };
    }
  }
  is_deeply( hashes( $engine->aggregate_tool_calls( \@one ) ), hashes( $engine->aggregate_tool_calls( \@two ) ),
    'interleaved streams each assemble their own call' );
  is( scalar @{ $engine->aggregate_tool_calls( \@one ) }, 1, 'no fragment bleeds into the other stream' );

  # A stream cut off before finish_reason must not leak its fragments into the
  # next stream on the same engine.
  $engine->process_stream_data( sse( openai_stream_events( truncated => 1 ) ) );
  my $next = $engine->process_stream_data( sse(
    { choices => [ { index => 0, delta => { content => 'hi' } } ] },
    { choices => [ { index => 0, delta => {}, finish_reason => 'stop' } ] } ) );
  ok( !( grep { $_->has_tool_calls } @$next ), 'a truncated stream leaves nothing behind' );
};

# ---------------------------------------------------------------------------
# Anthropic Messages: a tool_use block assembled from input_json_delta,
# delivered on its content_block_stop.
# ---------------------------------------------------------------------------

my $an_capture = $json->decode( path('t/data/akianthropic_tool_call_response.json')->slurp_raw );
my $an_block   = $an_capture->{content}[0];

sub anthropic_stream_events {
  return (
    { type => 'message_start', message => { id => $an_capture->{id}, type => 'message', role => 'assistant',
      model => $an_capture->{model}, content => [], stop_reason => undef, usage => { input_tokens => 227 } } },
    { type => 'content_block_start', index => 0, content_block => { type => 'text', text => '' } },
    { type => 'content_block_delta', index => 0, delta => { type => 'text_delta', text => 'Adding.' } },
    { type => 'content_block_stop', index => 0 },
    { type => 'content_block_start', index => 1, content_block => {
      type => 'tool_use', id => $an_block->{id}, name => $an_block->{name}, input => {} } },
    { type => 'content_block_delta', index => 1, delta => { type => 'input_json_delta', partial_json => '' } },
    { type => 'content_block_delta', index => 1, delta => { type => 'input_json_delta', partial_json => '{"a": 7' } },
    { type => 'content_block_delta', index => 1, delta => { type => 'input_json_delta', partial_json => ', "b": 15}' } },
    { type => 'content_block_stop', index => 1 },
    { type => 'message_delta', delta => { stop_reason => 'tool_use', stop_sequence => undef },
      usage => { output_tokens => 23 } },
    { type => 'message_stop' },
  );
}

subtest 'Anthropic: tool_use block, parity with the AKI.IO /anthropic capture' => sub {
  my $engine = Langertha::Engine::AKIAnthropic->new( api_key => 'k', model => 'llama3-chat-8b' );
  my $chunks = $engine->process_stream_data( sse_ev( anthropic_stream_events() ) );
  my $tcs    = $engine->aggregate_tool_calls($chunks);

  is_deeply( hashes($tcs), reply_calls( $engine, 't/data/akianthropic_tool_call_response.json' ),
    'the streamed call equals the one chat_response reads off the capture' );
  is( scalar @$tcs, 1, 'delivered exactly once' );
  is_deeply( $tcs->[0]->arguments, { a => 7, b => 15 }, 'input assembled from partial_json' );
  my ($carrier) = grep { $_->has_tool_calls } @$chunks;
  is( $carrier->raw->{type}, 'content_block_stop', 'the call rides its content_block_stop' );
  is( join( '', map { $_->content } @$chunks ), 'Adding.', 'text unchanged' );
  ok( $chunks->[-1]->is_final, 'final chunk still message_stop' );
  is( $chunks->[-1]->finish_reason, 'tool_use', 'finish_reason tool_use as in the reply' );
};

subtest 'Anthropic: a tool_use with no input deltas keeps its start input' => sub {
  my $engine = Langertha::Engine::Anthropic->new( api_key => 'k', model => 'claude-opus-4-8' );
  my $chunks = $engine->process_stream_data( sse_ev(
    { type => 'message_start', message => { id => 'm' } },
    { type => 'content_block_start', index => 0, content_block => {
      type => 'tool_use', id => 'toolu_1', name => 'ping', input => {} } },
    { type => 'content_block_stop', index => 0 },
    { type => 'message_stop' } ) );
  my $tcs = $engine->aggregate_tool_calls($chunks);
  is( scalar @$tcs, 1, 'one call' );
  is_deeply( $tcs->[0]->to_hash, { name => 'ping', arguments => {}, id => 'toolu_1', synthetic => 0 },
    'empty arguments, id kept' );
};

# ---------------------------------------------------------------------------
# Gemini: functionCall parts arrive whole, on the chunk that carries them.
# ---------------------------------------------------------------------------

subtest 'Gemini: functionCall parts' => sub {
  my $engine = Langertha::Engine::Gemini->new( api_key => 'k', model => 'gemini-3-flash-preview' );
  my @parts = (
    { functionCall => { name => 'get_weather', args => { city => 'Paris' } } },
    { functionCall => { name => 'get_time', args => { tz => 'CET' } } },
  );
  my $reply = reply_calls( $engine, { candidates => [ { content => { role => 'model',
    parts => [ { text => 'Checking.' }, @parts ] }, finishReason => 'STOP' } ] } );
  my $chunks = $engine->process_stream_data( sse(
    { candidates => [ { content => { role => 'model', parts => [ { text => 'Checking.' } ] } } ] },
    { candidates => [ { content => { role => 'model', parts => [ @parts ] }, finishReason => 'STOP' } ],
      usageMetadata => { promptTokenCount => 5, candidatesTokenCount => 9, totalTokenCount => 14 } },
  ) );
  is_deeply( hashes( $engine->aggregate_tool_calls($chunks) ), $reply,
    'both calls equal the non-streaming reply' );
  ok( !$chunks->[0]->has_tool_calls, 'text chunk carries none' );
  ok( $chunks->[1]->has_tool_calls, 'the functionCall chunk carries them' );
  is( $chunks->[1]->finish_reason, 'STOP', 'finishReason as the provider sent it' );
};

# ---------------------------------------------------------------------------
# Ollama native: message.tool_calls arrive whole.
# ---------------------------------------------------------------------------

subtest 'Ollama native: message.tool_calls, parity with the capture' => sub {
  my $engine  = Langertha::Engine::Ollama->new( url => 'http://test.invalid:11434', model => 'qwen3:8b' );
  my $capture = $json->decode( path('t/data/ollama_tool_call_response.json')->slurp_raw );
  my $chunks  = $engine->process_stream_data( ndjson(
    { model => 'qwen3:8b', created_at => $capture->{created_at}, done => JSON->false,
      message => { role => 'assistant', content => '', tool_calls => $capture->{message}{tool_calls} } },
    { model => 'qwen3:8b', created_at => $capture->{created_at}, done => JSON->true, done_reason => 'stop',
      message => { role => 'assistant', content => '' }, eval_count => 228, prompt_eval_count => 153 },
  ) );
  my $tcs = $engine->aggregate_tool_calls($chunks);
  is_deeply( hashes($tcs), reply_calls( $engine, 't/data/ollama_tool_call_response.json' ),
    'the streamed call equals the one chat_response reads off the capture' );
  is( scalar @$tcs, 1, 'delivered exactly once' );
  ok( $chunks->[0]->has_tool_calls && !$chunks->[1]->has_tool_calls, 'on the chunk that carried it' );
  is( $chunks->[1]->finish_reason, 'stop', 'done_reason unchanged' );
};

# ---------------------------------------------------------------------------
# Across the real transport (ADR 0027): chat_stream_realtime_f over the sync
# LWP shim and Net::Async::HTTP against a local daemon. The engines record the
# request body they built, so the same run checks that canonical Tool objects
# reach the wire serialized for the engine's tool_wire_format, while a tool
# hash (already the caller's wire shape) passes through untouched.
# ---------------------------------------------------------------------------

{
  package Test::RecordingOpenAI;
  use Moose;
  extends 'Langertha::Engine::AKIOpenAI';
  has sent => ( is => 'rw' );
  around chat_stream_request => sub {
    my ( $orig, $self, @args ) = @_;
    my $request = $self->$orig(@args);
    $self->sent( JSON::MaybeXS->new( utf8 => 1 )->decode( $request->content ) );
    return $request;
  };
  __PACKAGE__->meta->make_immutable;
}
{
  package Test::RecordingAnthropic;
  use Moose;
  extends 'Langertha::Engine::AKIAnthropic';
  has sent => ( is => 'rw' );
  around chat_stream_request => sub {
    my ( $orig, $self, @args ) = @_;
    my $request = $self->$orig(@args);
    $self->sent( JSON::MaybeXS->new( utf8 => 1 )->decode( $request->content ) );
    return $request;
  };
  __PACKAGE__->meta->make_immutable;
}

SKIP: {
  skip 'fork-based HTTP::Daemon test not supported on Windows', 1 if $^O eq 'MSWin32';
  require Test::LocalHTTPDaemon;

  my $server = Test::LocalHTTPDaemon->start( sub {
    my ($request) = @_;
    my @events = $request->uri->path =~ m{/v1/messages\z}
      ? ( map { sse_ev($_) } anthropic_stream_events() )
      : ( ( map { sse($_) } openai_stream_events() ), "data: [DONE]\n\n" );
    return HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'text/event-stream' ], sub {
      return shift(@events) // '';
    } );
  } );
  my $base = $server->url;

  my @backends = ( [ 'sync LWP shim', sub {
    ( _async_http => Langertha::Request::SyncHTTP->new( user_agent => LWP::UserAgent->new( timeout => 10 ) ) ) } ] );
  push @backends, [ 'Net::Async::HTTP', sub { () } ]
    if eval { require Net::Async::HTTP; require IO::Async::Loop; 1 };

  my $tool = Langertha::Tool->new( name => 'add', description => 'Add two numbers',
    input_schema => { type => 'object', properties => { a => { type => 'number' }, b => { type => 'number' } } } );
  my $server_tool = { type => 'web_search_20250305', name => 'web_search', max_uses => 1 };
  my $cached_tool  = { name => 'mul', input_schema => { type => 'object', properties => {} },
    cache_control => { type => 'ephemeral' } };

  for my $backend (@backends) {
    my ( $label, $args ) = @$backend;
    subtest "$label: chat_stream_realtime_f" => sub {
      my $oa = Test::RecordingOpenAI->new( api_key => 'k', model => 'llama3-chat-8b',
        url => "$base/v1", $args->() );
      my ( $content, $chunks ) = $oa->chat_stream_realtime_f(
        messages => ['add 7 and 15'], tools => [$tool] )->get;
      is_deeply( hashes( $oa->aggregate_tool_calls($chunks) ),
        reply_calls( $oa, 't/data/akiopenai_tool_call_response.json' ), 'OpenAI: streamed call matches the reply' );
      is_deeply( $oa->sent->{tools}, Langertha::Tool->format_list( 'openai', [$tool] ),
        'OpenAI: a canonical Tool goes on the wire in the openai shape' );

      my $an = Test::RecordingAnthropic->new( api_key => 'k', model => 'llama3-chat-8b',
        url => $base, $args->() );
      ( $content, $chunks ) = $an->chat_stream_realtime_f(
        messages => ['add 7 and 15'], tools => [ $tool, $server_tool, $cached_tool ] )->get;
      is_deeply( hashes( $an->aggregate_tool_calls($chunks) ),
        reply_calls( $an, 't/data/akianthropic_tool_call_response.json' ), 'Anthropic: streamed call matches the reply' );
      is( $content, 'Adding.', 'Anthropic: text still streams' );
      is_deeply( $an->sent->{tools},
        [ @{ Langertha::Tool->format_list( 'anthropic', [$tool] ) }, $server_tool, $cached_tool ],
        'Anthropic: a canonical Tool is serialized; wire-shaped hashes (a built-in, cache_control) pass through untouched' );
    };
  }
}

done_testing;
