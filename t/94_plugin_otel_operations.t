#!/usr/bin/env perl
# ABSTRACT: Langertha::Plugin::OTel spans for embeddings and image generation, and the async flush, against a local HTTP::Daemon

use strict;
use warnings;

use Test2::Bundle::More;
use lib 't/lib';

BEGIN {
  plan skip_all => 'fork-based HTTP::Daemon test not supported on Windows' if $^O eq 'MSWin32';
}

use File::Temp ();
use HTTP::Response;
use JSON::MaybeXS;
use Test::LocalHTTPDaemon;

use Langertha::Embedder;
use Langertha::Engine::OpenAI;
use Langertha::ImageGen;
use Langertha::Plugin::OTel;

# A developer's own OpenTelemetry setup must not leak into the expectations.
delete @ENV{ grep { /\A OTEL_ /x } keys %ENV };

my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );

my $log = File::Temp->new;
my $log_name = $log->filename;

sub received_traces {
  open my $fh, '<', $log_name or return ();
  my @lines = <$fh>;
  close $fh;
  return map { $json->decode($_) } @lines;
}

sub clear_log { open my $fh, '>', $log_name or die $!; close $fh }

sub json_response {
  return HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'application/json' ], JSON::MaybeXS->new( utf8 => 1 )->encode( $_[0] ) );
}

my $server = Test::LocalHTTPDaemon->start( sub {
  my ($request) = @_;
  my $path = $request->uri->path;
  if ( $path =~ m{/traces\z} ) {
    open my $out, '>>', $log_name or die $!;
    print {$out} $request->content, "\n";
    close $out;
    return json_response( {} );
  }
  return json_response( { model => '20240101', data => [ { index => 0, embedding => [ 0.5, 1, 2 ] } ],
      usage => { prompt_tokens => 7, total_tokens => 7 } } ) if $path =~ m{/embeddings\z};
  return json_response( { created => 1, data => [ { b64_json => 'aGk=' } ],
      usage => { input_tokens => 9, output_tokens => 100, total_tokens => 109 } } ) if $path =~ m{/images/generations\z};
  return HTTP::Response->new( 404, 'Not Found' );
} );
my $base = $server->url;

sub engine { Langertha::Engine::OpenAI->new( api_key => 'sk-test', url => "$base/v1" ) }

sub plugin_spec {
  my (%args) = @_;
  return [ OTel => { endpoint => "$base/otlp/v1/traces", headers => {}, %args } ];
}

sub otel_of { my ($host) = @_; my ($otel) = grep { $_->isa('Langertha::Plugin::OTel') } @{ $host->plugin_instances }; return $otel }

sub spans_of { my ($otel) = @_; return $json->decode( $otel->_otlp->to_json( $otel->_batch ) )->{resourceSpans}[0]{scopeSpans}[0]{spans} }

sub attrs_of { return { map { $_->{key} => $_->{value} } @{ $_[0]{attributes} } } }

subtest 'embedding: client span "embeddings <model>"' => sub {
  my $embedder = Langertha::Embedder->new( engine => engine(), model => 'emb-model-x',
    plugins => plugin_spec( session_id => 'conv-1' ) );
  my $otel = otel_of($embedder);
  my $vector = $embedder->simple_embedding('SECRET-EMBED-TEXT');
  is_deeply( $vector, [ 0.5, 1, 2 ], 'the embedding itself is unaffected' );
  my @spans = @{ spans_of($otel) };
  is( scalar @spans, 1, 'one span' );
  my $span = $spans[0];
  is_deeply( $span->{name}, 'embeddings emb-model-x', 'span name' );
  is_deeply( $span->{kind}, 3, 'CLIENT' );
  ok( !exists $span->{parentSpanId}, 'top level' );
  my $a = attrs_of($span);
  is_deeply( $a->{'gen_ai.operation.name'}, { stringValue => 'embeddings' }, 'operation embeddings' );
  is_deeply( $a->{'gen_ai.provider.name'}, { stringValue => 'openai' }, 'provider' );
  is_deeply( $a->{'gen_ai.request.model'}, { stringValue => 'emb-model-x' }, 'request model = Embedder override' );
  is_deeply( $a->{'gen_ai.embeddings.dimension.count'}, { intValue => '3' }, 'dimension count as intValue' );
  is_deeply( $a->{'gen_ai.conversation.id'}, { stringValue => 'conv-1' }, 'conversation id' );
  is_deeply( $a->{'session.id'}, { stringValue => 'conv-1' }, 'session id' );
  is_deeply( $a->{'server.port'}, { intValue => ( $server->url =~ /:(\d+)\z/ )[0] }, 'server.port of the engine url' );
  ok( !exists $a->{'gen_ai.request.temperature'}, 'no chat parameters' );
  unlike( $json->encode( $span ), qr/SECRET-EMBED-TEXT/, 'embedded text stays out (capture_content off)' );
  unlike( $json->encode( $span ), qr/0\.5/, 'vector values stay out' );
};

subtest 'embedding via simple_embedding_result: model and usage from the CallResult' => sub {
  my $embedder = Langertha::Embedder->new( engine => engine(), plugins => plugin_spec() );
  my $otel = otel_of($embedder);
  my $result = $embedder->simple_embedding_result('hello');
  is_deeply( $result->value, [ 0.5, 1, 2 ], 'value' );
  my ($span) = @{ spans_of($otel) };
  my $a = attrs_of($span);
  is_deeply( $a->{'gen_ai.response.model'}, { stringValue => '20240101' }, 'numeric-looking model stays a string' );
  is_deeply( $a->{'gen_ai.usage.input_tokens'}, { intValue => '7' }, 'input tokens from the CallResult usage' );
  ok( !exists $a->{'gen_ai.usage.output_tokens'},
    'no output tokens: the embeddings wire reports none, so none is sent (not 0)' );
  ok( $span->{endTimeUnixNano} >= $span->{startTimeUnixNano}, 'end >= start' );
};

subtest 'image generation: generate_content span with gen_ai.output.type=image' => sub {
  my $image_gen = Langertha::ImageGen->new( engine => engine(), model => 'img-model', plugins => plugin_spec() );
  my $otel = otel_of($image_gen);
  my $result = $image_gen->simple_image_result('PROMPT-IMAGE-SECRET');
  ok( $result, 'got a result' );
  my @spans = @{ spans_of($otel) };
  is( scalar @spans, 1, 'one span' );
  my $span = $spans[0];
  my $a = attrs_of($span);
  is_deeply( $span->{name}, 'generate_content img-model', 'span name' );
  is_deeply( $span->{kind}, 3, 'CLIENT' );
  is_deeply( $a->{'gen_ai.operation.name'}, { stringValue => 'generate_content' }, 'operation' );
  is_deeply( $a->{'gen_ai.output.type'}, { stringValue => 'image' }, 'output type image' );
  is_deeply( $a->{'gen_ai.request.model'}, { stringValue => 'img-model' }, 'request model' );
  is_deeply( $a->{'gen_ai.usage.input_tokens'}, { intValue => '9' }, 'usage from the CallResult' );
  is_deeply( $a->{'gen_ai.usage.output_tokens'}, { intValue => '100' }, 'output tokens' );
  unlike( $json->encode($span), qr/PROMPT-IMAGE-SECRET/, 'prompt stays out by default' );
  unlike( $json->encode($span), qr/aGk=/, 'image data stays out' );

  my $capturing = Langertha::ImageGen->new( engine => engine(), plugins => plugin_spec( capture_content => 1 ) );
  my $otel2 = otel_of($capturing);
  $capturing->simple_image('PROMPT-IMAGE-CAPTURED');
  my ($span2) = @{ spans_of($otel2) };
  my $messages = $json->decode( attrs_of($span2)->{'gen_ai.input.messages'}{stringValue} );
  is_deeply( $messages, [ { role => 'user', parts => [ { type => 'text', content => 'PROMPT-IMAGE-CAPTURED' } ] } ],
    'with capture_content the prompt is the input message' );
  unlike( $json->encode($span2), qr/aGk=/, 'image data still stays out' );
};

subtest 'one trace across mixed operations, until reset_trace' => sub {
  my $embedder = Langertha::Embedder->new( engine => engine(), plugins => plugin_spec() );
  my $otel = otel_of($embedder);
  $embedder->simple_embedding('a');
  $embedder->simple_embedding('b');
  $otel->reset_trace;
  $embedder->simple_embedding('c');
  my @spans = @{ spans_of($otel) };
  is_deeply( $spans[0]{traceId}, $spans[1]{traceId}, 'same trace' );
  isnt( $spans[2]{traceId}, $spans[0]{traceId}, 'new trace after reset_trace' );
};

SKIP: {
  skip "Net::Async::HTTP / IO::Async not installed", 3
    unless eval { require Net::Async::HTTP; require IO::Async::Loop; 1 };

  subtest 'flush_f and auto_flush over Net::Async::HTTP' => sub {
    clear_log();
    my $loop = IO::Async::Loop->new;
    my $embedder = Langertha::Embedder->new( engine => engine(), plugins => plugin_spec() );
    my $otel = otel_of($embedder);
    ok( $embedder->engine->async_loop, 'the engine runs the async backend' );
    my $call = $embedder->simple_embedding_f('async');
    $loop->await($call);
    is_deeply( $call->get, [ 0.5, 1, 2 ], 'async embedding unaffected' );
    is( scalar @{ $otel->_batch }, 1, 'span recorded' );
    my $future = $otel->flush_f;
    $loop->await($future);
    ok( $future->is_done, 'flush_f done' );
    ok( $future->get->is_success, 'got the response' );
    my @bodies = received_traces();
    is( scalar @bodies, 1, 'one OTLP request reached the daemon' );
    is_deeply( $bodies[0]->{resourceSpans}[0]{scopeSpans}[0]{spans}[0]{name}, 'embeddings ' . $embedder->engine->embedding_model,
      'span in the request' );
  };

  subtest 'auto_flush returns without waiting; flush waits for it' => sub {
    clear_log();
    my $loop = IO::Async::Loop->new;
    my $embedder = Langertha::Embedder->new( engine => engine(), plugins => plugin_spec( auto_flush => 1 ) );
    my $otel = otel_of($embedder);
    my $call = $embedder->simple_embedding_f('async');
    $loop->await($call);
    ok( $call->is_done, 'the call completed' );
    $loop->await($_) for values %{ $otel->_pending_flushes };
    is( scalar @{ $otel->_batch }, 0, 'batch handed to the flush' );
    is( scalar( () = received_traces() ), 1, 'the auto flush request arrived' );
  };

  subtest 'async failure of the endpoint is a warning, not a failure' => sub {
    my $loop = IO::Async::Loop->new;
    my $engine = Langertha::Engine::OpenAI->new( api_key => 'sk-test', url => "$base/v1" );
    my $embedder = Langertha::Embedder->new( engine => $engine,
      plugins => plugin_spec( endpoint => 'http://127.0.0.1:1/v1/traces', flush_timeout => 3 ) );
    my $otel = otel_of($embedder);
    $embedder->simple_embedding('x');
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $future = $otel->flush_f;
    $loop->await($future);
    ok( $future->is_done, 'flush_f resolved, did not fail' );
    like( join( '', @warnings ), qr/OTLP trace export failed/, 'warned' );
  };
}

done_testing;
