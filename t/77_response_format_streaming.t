#!/usr/bin/env perl
# ABSTRACT: Per-request response_format must reach the streaming wire on Anthropic, Ollama and Gemini

# karr #52: chat_stream_request ignored response_format in all three engines —
# an engine-attribute response_format was silently dropped on streaming, and a
# per-request one would have leaked as a top-level field once #42
# (chat_stream_realtime_f with %opts) opened the pass-through path.
#
# Gemini and Ollama now translate response_format to their native wire form
# (generationConfig.responseSchema / format) exactly like chat_request, with
# per-request beating the engine attribute and the key deleted from the extras.
#
# Anthropic-family engines have no native response_format and no streaming
# counterpart to the chat_response tool_use lift (ADR 0005 paragraph 2), so
# chat_stream_request consumes the key and croaks instead of leaking it (HTTP
# 400) or silently streaming unstructured text.

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;

use Langertha::Engine::Anthropic;
use Langertha::Engine::Ollama;
use Langertha::Engine::Gemini;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

my $SCHEMA = {
  type       => 'object',
  properties => { city => { type => 'string' } },
  required   => ['city'],
};
my $OTHER_SCHEMA = {
  type       => 'object',
  properties => { country => { type => 'string' } },
};

sub anthropic {
  return Langertha::Engine::Anthropic->new(
    api_key       => 'apikey',
    model         => 'claude-x',
    response_size => 256,
    @_,
  );
}

sub ollama {
  return Langertha::Engine::Ollama->new(
    url   => 'http://test.url:12345',
    model => 'model',
    @_,
  );
}

sub gemini {
  return Langertha::Engine::Gemini->new(
    api_key => 'apikey',
    model   => 'gemini-3-flash-preview',
    @_,
  );
}

sub stream_wire {
  my ( $engine, %extra ) = @_;
  return $json->decode(
    $engine->chat_stream_request( $engine->chat_messages('testprompt'), %extra )->content
  );
}

# --- Anthropic: streaming response_format is refused, not leaked ----------
{
  my $engine = anthropic();
  my $ok = eval { stream_wire( $engine, response_format => {
    type        => 'json_schema',
    json_schema => { name => 'extract', description => 'extractor', schema => $SCHEMA },
  }); 1 };
  ok( !$ok, 'Anthropic: streaming json_schema croaks' );
  like( $@, qr/cannot stream response_format/,
    'Anthropic: croak names the streaming limitation' );
  like( $@, qr/chat_f\/chat_request/,
    'Anthropic: croak points at the non-streaming structured-output path' );
}

{
  my $engine = anthropic();
  my $ok = eval { stream_wire( $engine, response_format => { type => 'json_object' } ); 1 };
  ok( !$ok, 'Anthropic: streaming json_object croaks' );
  like( $@, qr/cannot stream response_format/,
    'Anthropic: json_object croak names the streaming limitation' );
}

# --- Anthropic: engine-attribute response_format is refused too ----------
# karr #52 Folge 1: an engine constructed with response_format and then
# streamed must not silently produce unstructured text.
{
  my $engine = anthropic( response_format => {
    type        => 'json_schema',
    json_schema => { name => 'engine_level', schema => $OTHER_SCHEMA },
  });
  my $ok = eval { stream_wire($engine); 1 };
  ok( !$ok, 'Anthropic: engine-attribute response_format croaks on streaming' );
  like( $@, qr/cannot stream response_format/,
    'Anthropic: engine-attribute croak names the streaming limitation' );
}

# --- Anthropic: a response_format the engine would ignore stays a no-op ---
# The croak fires only when the non-streaming path would actually honor the
# response_format; an unknown type is consumed and dropped on both paths.
{
  my $data = stream_wire( anthropic(), response_format => { type => 'text' } );

  ok( !exists $data->{response_format},
    'Anthropic: non-honored response_format is consumed, not passed to the wire' );
  is( $data->{stream}, JSON->true, 'Anthropic: stream request still streams' );
  ok( !exists $data->{tools} && !exists $data->{tool_choice},
    'Anthropic: no synthesized tool is injected for a non-honored response_format' );
}

# --- Anthropic: plain streaming is unaffected -----------------------------
{
  my $data = stream_wire( anthropic() );

  is( $data->{stream}, JSON->true, 'Anthropic: plain stream request streams' );
  ok( !exists $data->{response_format},
    'Anthropic: no response_format key on a plain stream request' );
}

# --- Ollama: per-request json_schema -------------------------------------
{
  my $data = stream_wire( ollama(), response_format => {
    type        => 'json_schema',
    json_schema => { name => 'extract', schema => $SCHEMA },
  });

  ok( !exists $data->{response_format},
    'Ollama: per-request response_format is consumed, not passed to the wire' );
  is_deeply( $data->{format}, $SCHEMA,
    'Ollama: per-request json_schema becomes the format schema' );
  is( $data->{stream}, JSON->true, 'Ollama: stream request still streams' );
}

# --- Ollama: per-request json_object -------------------------------------
{
  my $data = stream_wire( ollama(), response_format => { type => 'json_object' } );

  ok( !exists $data->{response_format},
    'Ollama: per-request json_object is consumed, not passed to the wire' );
  is( $data->{format}, 'json', 'Ollama: per-request json_object becomes format=json' );
}

# --- Ollama: per-request beats engine attribute and json_format ----------
{
  my $engine = ollama(
    json_format     => 1,
    response_format => { type => 'json_object' },
  );
  my $data = stream_wire( $engine, response_format => {
    type        => 'json_schema',
    json_schema => { name => 'extract', schema => $SCHEMA },
  });

  is_deeply( $data->{format}, $SCHEMA,
    'Ollama: per-request response_format wins over engine attribute and json_format' );
}

# --- Ollama: engine attribute alone still works ---------------------------
{
  my $data = stream_wire( ollama( response_format => {
    type        => 'json_schema',
    json_schema => { name => 'engine_level', schema => $OTHER_SCHEMA },
  }));

  is_deeply( $data->{format}, $OTHER_SCHEMA,
    'Ollama: engine-attribute response_format still translates on streaming' );

  my $legacy = stream_wire( ollama( json_format => 1 ) );
  is( $legacy->{format}, 'json', 'Ollama: legacy json_format attribute still works on streaming' );
}

# --- Gemini: per-request json_schema -------------------------------------
{
  my $data = stream_wire( gemini(), response_format => {
    type        => 'json_schema',
    json_schema => { name => 'extract', schema => $SCHEMA },
  });

  ok( !exists $data->{response_format},
    'Gemini: per-request response_format is consumed, not passed to the wire' );
  is_deeply( $data->{generationConfig}{responseSchema}, $SCHEMA,
    'Gemini: per-request json_schema becomes generationConfig.responseSchema' );
  is( $data->{generationConfig}{responseMimeType}, 'application/json',
    'Gemini: per-request json_schema sets responseMimeType' );
}

# --- Gemini: per-request json_object -------------------------------------
{
  my $data = stream_wire( gemini(), response_format => { type => 'json_object' } );

  ok( !exists $data->{response_format},
    'Gemini: per-request json_object is consumed, not passed to the wire' );
  is( $data->{generationConfig}{responseMimeType}, 'application/json',
    'Gemini: per-request json_object sets responseMimeType' );
  ok( !exists $data->{generationConfig}{responseSchema},
    'Gemini: json_object leaves responseSchema unset' );
}

# --- Gemini: per-request beats the engine attribute ----------------------
{
  my $engine = gemini( response_format => {
    type        => 'json_schema',
    json_schema => { name => 'engine_level', schema => $OTHER_SCHEMA },
  });
  my $data = stream_wire( $engine, response_format => {
    type        => 'json_schema',
    json_schema => { name => 'per_request', schema => $SCHEMA },
  });

  is_deeply( $data->{generationConfig}{responseSchema}, $SCHEMA,
    'Gemini: per-request response_format wins over the engine attribute on streaming' );
}

# --- Gemini: engine attribute alone still works --------------------------
{
  my $data = stream_wire( gemini( response_format => {
    type        => 'json_schema',
    json_schema => { name => 'engine_level', schema => $OTHER_SCHEMA },
  }));

  is_deeply( $data->{generationConfig}{responseSchema}, $OTHER_SCHEMA,
    'Gemini: engine-attribute response_format still translates on streaming' );
}

done_testing;
