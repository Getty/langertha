#!/usr/bin/env perl
# ABSTRACT: Langertha::Plugin::OTel spans for streamed and failed chat calls (stream flag, ttft, error status and error.type, content gating), and Plugin::Langfuse for the same (no network)

use strict;
use warnings;

use Test2::Bundle::More;
use Path::Tiny;
use IO::Socket::INET;
use JSON::MaybeXS;

use lib path(__FILE__)->parent->child('lib')->stringify;

use Test::MockMCP;

use Langertha::Chat;
use Langertha::Engine::Virtual;
use Langertha::Plugin::OTel;
use Langertha::Virtual::Rules qw( answer tool after error );

my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );

my %SENTINEL = (
  error  => 'ERROR-SENTINEL-8b27',
);

# A Virtual engine whose 'json error' answer is a provider-style JSON error
# body, as OpenAI sends it; the plain Virtual error is a text/plain body.
{
  package Test::JSONErrorVirtual;
  use Moose;
  extends 'Langertha::Engine::Virtual';
  around virtual_reply => sub {
    my ( $orig, $self, @args ) = @_;
    my $reply = $self->$orig(@args);
    return $reply unless $reply->{code} == 429;
    return { code => 429, message => 'Too Many Requests', content => { error => {
      message => "$SENTINEL{error} quota", type => 'requests', code => 'rate_limit_exceeded',
    } } };
  };
  __PACKAGE__->meta->make_immutable;
}

{
  package Test::StreamAbort;
  sub new { bless {}, $_[0] }
}

my $mcp = Test::MockMCP->new( tools => [
  { name => 'lookup', description => 'Look something up',
    input_schema => { type => 'object', properties => { query => { type => 'string' } } },
    code => sub { my ( $self ) = @_; return $self->text_result('found') } },
] );

sub engine {
  my ( $class, @extra ) = @_;
  return ( $class // 'Langertha::Engine::Virtual' )->new(
    langfuse_enabled => 0,
    rules => [
      qr/\Aboom\b/      => sub { error( 500, "upstream down $SENTINEL{error}" ) },
      qr/\Alimit\b/     => sub { error( 429, "slow down $SENTINEL{error}" ) },
      qr/\Atool boom\z/ => sub { tool( lookup => { query => 'x' } ) },
      after('lookup')   => sub { error( 503, 'second call down' ) },
    ],
    fallback => answer( 'streamed answer', usage => { prompt_tokens => 7, completion_tokens => 3 } ),
    @extra,
  );
}

sub free_port {
  my $socket = IO::Socket::INET->new( Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0 ) or die $!;
  my $port = $socket->sockport;
  close $socket;
  return $port;
}

sub chat_with_otel {
  my ( %args ) = @_;
  my $chat = Langertha::Chat->new(
    engine      => $args{engine} || engine(),
    mcp_servers => [$mcp],
    plugins     => [ OTel => { endpoint => 'http://127.0.0.1:' . free_port() . '/v1/traces', headers => {},
      %{ $args{plugin} || {} } } ],
  );
  my ($otel) = grep { $_->isa('Langertha::Plugin::OTel') } @{ $chat->plugin_instances };
  return ( $chat, $otel );
}

sub payload  { my ($otel) = @_; return $otel->_otlp->to_json( $otel->_batch ) }
sub spans_of { my ($otel) = @_; return $json->decode( payload($otel) )->{resourceSpans}[0]{scopeSpans}[0]{spans} }
sub attrs_of { my ($span) = @_; return { map { $_->{key} => $_->{value} } @{ $span->{attributes} } } }

subtest 'sync stream: one CLIENT chat span with stream=true, usage, model, finish reason' => sub {
  my ( $chat, $otel ) = chat_with_otel();
  my $text = $chat->simple_chat_stream( sub { }, 'hello' );
  is( $text, 'streamed answer', 'the stream answered' );
  my @spans = @{ spans_of($otel) };
  is( scalar @spans, 1, 'one span' );
  my $span = $spans[0];
  is( $span->{name}, 'chat virtual', 'span name' );
  is( $span->{kind}, 3, 'CLIENT' );
  ok( !exists $span->{status}, 'status unset on success' );
  my $attr = attrs_of($span);
  is_deeply( $attr->{'gen_ai.request.stream'}, { boolValue => JSON::MaybeXS::true() }, 'gen_ai.request.stream true' );
  is_deeply( $attr->{'gen_ai.response.model'}, { stringValue => 'virtual' }, 'response model from the stream' );
  is_deeply( $attr->{'gen_ai.response.finish_reasons'}, { arrayValue => { values => [ { stringValue => 'stop' } ] } },
    'finish reason from the stream' );
  is_deeply( $attr->{'gen_ai.usage.input_tokens'},  { intValue => '7' }, 'input tokens from the stream' );
  is_deeply( $attr->{'gen_ai.usage.output_tokens'}, { intValue => '3' }, 'output tokens from the stream' );
  ok( !exists $attr->{'gen_ai.response.time_to_first_chunk'}, 'no ttft on the sync path (body read first)' );
  ok( !exists $attr->{'gen_ai.response.id'}, 'no response id: chunks carry none' );
  ok( !exists $attr->{'error.type'}, 'no error type' );
};

subtest 'realtime stream: time_to_first_chunk as a double' => sub {
  my ( $chat, $otel ) = chat_with_otel();
  my ( $content, undef, $timing ) = $chat->simple_chat_stream_realtime_f( undef, 'hello' )->get;
  is( $content, 'streamed answer', 'answered' );
  my ($span) = @{ spans_of($otel) };
  my $attr = attrs_of($span);
  is_deeply( $attr->{'gen_ai.request.stream'}, { boolValue => JSON::MaybeXS::true() }, 'stream true' );
  ok( exists $attr->{'gen_ai.response.time_to_first_chunk'}{doubleValue}, 'time_to_first_chunk is a doubleValue' );
  is( $attr->{'gen_ai.response.time_to_first_chunk'}{doubleValue}, $timing->{ttft_seconds}, '... the measured ttft' );
  is_deeply( $attr->{'gen_ai.usage.input_tokens'}, { intValue => '7' }, 'usage' );
};

subtest 'a non-streamed call carries no stream attribute' => sub {
  my ( $chat, $otel ) = chat_with_otel();
  $chat->simple_chat('hello');
  ok( !exists attrs_of( spans_of($otel)->[0] )->{'gen_ai.request.stream'}, 'no gen_ai.request.stream' );
};

subtest 'failed calls: status ERROR, error.type, no message without capture_content' => sub {
  my @cases = (
    [ 'sync simple_chat', sub { $_[0]->simple_chat('boom'); 1 }, '500', 0 ],
    [ 'simple_chat_f',    sub { $_[0]->simple_chat_f('boom')->get; 1 }, '500', 0 ],
    [ 'sync stream',      sub { $_[0]->simple_chat_stream( sub { }, 'limit' ); 1 }, '429', 1 ],
    [ 'realtime stream',  sub { $_[0]->simple_chat_stream_realtime_f( undef, 'limit' )->get; 1 }, '429', 1 ],
  );
  for my $case (@cases) {
    my ( $label, $run, $type, $stream ) = @$case;
    my ( $chat, $otel ) = chat_with_otel();
    ok( !eval { $run->( $chat ) }, "$label: the call still fails for the caller" );
    my @spans = @{ spans_of($otel) };
    is( scalar @spans, 1, "$label: one span for the failed call" );
    my $span = $spans[0];
    is( $span->{name}, 'chat virtual', "$label: chat span" );
    is_deeply( $span->{status}, { code => 2 }, "$label: status ERROR (2), no message" );
    my $attr = attrs_of($span);
    is_deeply( $attr->{'error.type'}, { stringValue => $type }, "$label: error.type is the HTTP status $type" );
    if ($stream) {
      is_deeply( $attr->{'gen_ai.request.stream'}, { boolValue => JSON::MaybeXS::true() }, "$label: stream true" );
    }
    else {
      ok( !exists $attr->{'gen_ai.request.stream'}, "$label: no stream attribute" );
    }
    unlike( payload($otel), qr/\Q$SENTINEL{error}\E/, "$label: the error text is not in the payload" );
  }
};

subtest 'failed calls: provider error code and exception class' => sub {
  my ( $chat, $otel ) = chat_with_otel( engine => engine('Test::JSONErrorVirtual') );
  ok( !eval { $chat->simple_chat('limit'); 1 }, 'fails' );
  is_deeply( attrs_of( spans_of($otel)->[0] )->{'error.type'}, { stringValue => 'rate_limit_exceeded' },
    'error.type is the provider error code from the JSON body' );
  unlike( payload($otel), qr/\Q$SENTINEL{error}\E/, 'the provider message is not in the payload' );

  my ( $chat2, $otel2 ) = chat_with_otel();
  my $f = $chat2->simple_chat_stream_realtime_f( sub { die Test::StreamAbort->new }, 'hello' );
  $f->await;
  ok( $f->is_failed, 'a dying callback fails the stream' );
  my $attr = attrs_of( spans_of($otel2)->[0] );
  is_deeply( $attr->{'error.type'}, { stringValue => 'Test::StreamAbort' }, 'error.type is the exception class' );

  my ( $chat3, $otel3 ) = chat_with_otel();
  ok( !eval { $chat3->simple_chat_stream( sub { die "plain\n" }, 'hello' ); 1 }, 'a plain die in the callback' );
  is_deeply( attrs_of( spans_of($otel3)->[0] )->{'error.type'}, { stringValue => '_OTHER' },
    'error.type _OTHER without class, code or error status' );
};

subtest 'capture_content: the error message becomes the status message' => sub {
  my ( $chat, $otel ) = chat_with_otel( plugin => { capture_content => 1 } );
  ok( !eval { $chat->simple_chat('boom'); 1 }, 'fails' );
  my ($span) = @{ spans_of($otel) };
  is( $span->{status}{code}, 2, 'ERROR' );
  like( $span->{status}{message}, qr/request failed: 500/, 'the first line of the error as the message' );
  unlike( $span->{status}{message}, qr/\n/, 'one line' );
};

subtest 'tool loops: the failing second call is an error span after the first call and its tool' => sub {
  for my $method (qw( simple_chat_with_tools simple_chat_with_tools_f )) {
    my ( $chat, $otel ) = chat_with_otel();
    my $ok = eval { my $r = $chat->$method('tool boom'); $r = $r->get if ref $r; 1 };
    ok( !$ok, "$method: fails" );
    my @spans = @{ spans_of($otel) };
    is_deeply( [ map { $_->{name} } @spans ], [ 'chat virtual', 'execute_tool lookup', 'chat virtual' ],
      "$method: chat, tool, failed chat" );
    ok( !exists $spans[0]{status}, "$method: the first call succeeded" );
    is_deeply( $spans[2]{status}, { code => 2 }, "$method: the second call failed" );
    is_deeply( attrs_of( $spans[2] )->{'error.type'}, { stringValue => '503' }, "$method: error.type 503" );
  }
};

subtest 'a failure does not disturb the next call' => sub {
  my ( $chat, $otel ) = chat_with_otel();
  ok( !eval { $chat->simple_chat('boom'); 1 }, 'first fails' );
  is( $chat->simple_chat('fine')->content, 'streamed answer', 'next call works' );
  my @spans = @{ spans_of($otel) };
  is( scalar @spans, 2, 'two spans' );
  ok( $spans[0]{status} && !$spans[1]{status}, 'error, then unset' );
};

subtest 'Plugin::Langfuse: streamed and failed generations' => sub {
  my $chat = Langertha::Chat->new(
    engine  => engine(),
    plugins => [ Langfuse => { public_key => 'pk-test', secret_key => 'sk-test',
      url => 'http://127.0.0.1:' . free_port() } ],
  );
  my ($langfuse) = @{ $chat->plugin_instances };
  $chat->simple_chat_stream_realtime_f( undef, 'hello' )->get;
  ok( !eval { $chat->simple_chat('boom'); 1 }, 'the failing call still dies' );
  my @generations = grep { $_->{type} eq 'generation-create' } @{ $langfuse->_batch };
  is( scalar @generations, 2, 'two generations' );
  my ( $streamed, $failed ) = map { $_->{body} } @generations;
  is( $streamed->{output}, 'streamed answer', 'the streamed generation has the answer' );
  is( $streamed->{usage}{input}, 7, '... and the usage' );
  ok( defined $streamed->{completionStartTime}, '... and the completion start' );
  is( $failed->{level}, 'ERROR', 'the failed generation is level ERROR' );
  like( $failed->{statusMessage}, qr/request failed: 500/, '... with the error as status message' );
  ok( !exists $streamed->{level}, 'the successful one has no level' );
};

done_testing;
