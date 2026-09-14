#!/usr/bin/env perl
# ABSTRACT: Per-engine capability-exclusion croak (karr #142) — Cerebras/Groq tools+response_format

# karr #142: a boolean capability flag cannot express a MUTUAL EXCLUSION
# between two capabilities in one request. Two providers reject a body that
# combines tools and a structured-output response_format with an opaque HTTP
# 400 (no body). chat_f/chat_stream_realtime_f consult a per-engine hook
# (_check_capability_exclusions, default no-op) that turns the known provider
# 400 into a clear LOCAL croak naming the engine and the conflicting fields.
#
#   Cerebras: tools + response_format (json_object OR json_schema) -> croak.
#   Groq: MODE-AWARE — tools + response_format json_schema -> croak, but
#         json_object + tools is provider-ALLOWED and must NOT croak. Groq
#         Structured Outputs also exclude streaming: response_format json_schema
#         on the streaming path croaks regardless of tools.
#
# All cases are MOCKED — no live API calls. The mock also makes the sabotage
# check hermetic: removing a guard lets the request reach the mock (returning a
# canned body on the non-streaming path, or dying on the missing streaming
# header) instead of a real provider, and the exclusion-message assertions then
# turn red because the croak no longer fires.

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;

use lib 't/lib';
use Test::MockAsyncHTTP;

use Langertha::Engine::Cerebras;
use Langertha::Engine::Groq;
use Langertha::Engine::OpenAI;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

my $SCHEMA = {
  type       => 'object',
  properties => { city => { type => 'string' } },
  required   => ['city'],
};

my $TOOL = {
  type     => 'function',
  function => {
    name        => 'get_weather',
    description => 'Get the weather for a city',
    parameters  => $SCHEMA,
  },
};

my $JSON_SCHEMA_RF = {
  type        => 'json_schema',
  json_schema => { name => 'extract', schema => $SCHEMA },
};
my $JSON_OBJECT_RF = { type => 'json_object' };

# A fresh mock per engine so the request never reaches a real provider even if
# a guard is removed (sabotage check stays offline).
sub mock {
  return Test::MockAsyncHTTP->new( responses => [
    Test::MockAsyncHTTP->mock_json_response({
      model   => 'gpt-oss-120b',
      choices => [{ message => { role => 'assistant', content => 'ok' } }],
    }),
  ]);
}

sub cerebras {
  return Langertha::Engine::Cerebras->new(
    api_key     => 'apikey',
    model       => 'gpt-oss-120b',
    _async_http => mock(),
    @_,
  );
}

sub groq {
  return Langertha::Engine::Groq->new(
    api_key     => 'apikey',
    model       => 'gpt-oss-120b',
    _async_http => mock(),
    @_,
  );
}

# Run a coderef that returns a Future and report ($ok, $err).
sub run {
  my ($code) = @_;
  my $ok = eval { $code->()->get; 1 };
  return ( $ok, $@ );
}

# ======================================================================
# Cerebras — tools + response_format (either type) is rejected
# ======================================================================

# --- Cerebras: tools + json_object -> croak -------------------------------
{
  my ( $ok, $err ) = run( sub { cerebras()->chat_f(
    messages        => ['weather?'],
    tools           => [$TOOL],
    response_format => $JSON_OBJECT_RF,
  ) });
  ok( !$ok, 'Cerebras: tools + response_format json_object croaks in chat_f' );
  like( $err, qr/Cerebras/, 'Cerebras json_object croak names the engine' );
  like( $err, qr/tools and response_format/,
    'Cerebras json_object croak names both conflicting fields' );
  like( $err, qr/400/, 'Cerebras json_object croak says the provider rejects it (400)' );
}

# --- Cerebras: tools + json_schema -> croak -------------------------------
{
  my ( $ok, $err ) = run( sub { cerebras()->chat_f(
    messages        => ['weather?'],
    tools           => [$TOOL],
    response_format => $JSON_SCHEMA_RF,
  ) });
  ok( !$ok, 'Cerebras: tools + response_format json_schema croaks in chat_f' );
  like( $err, qr/Cerebras/, 'Cerebras json_schema croak names the engine' );
}

# --- Cerebras: forced named tool_choice (no tools array) + rf -> croak ----
# The tool signal is "tools OR a forced tool_choice" — a forced named
# tool_choice trips the guard too.
{
  my ( $ok, $err ) = run( sub { cerebras()->chat_f(
    messages        => ['weather?'],
    tool_choice     => { type => 'tool', name => 'get_weather' },
    response_format => $JSON_OBJECT_RF,
  ) });
  ok( !$ok, 'Cerebras: forced tool_choice + response_format croaks in chat_f' );
  like( $err, qr/Cerebras/, 'Cerebras forced-tool_choice croak names the engine' );
}

# --- Cerebras: streaming path also croaks ---------------------------------
{
  my ( $ok, $err ) = run( sub { cerebras()->chat_stream_realtime_f(
    messages        => ['weather?'],
    tools           => [$TOOL],
    response_format => $JSON_SCHEMA_RF,
  ) });
  ok( !$ok, 'Cerebras: tools + response_format croaks on the streaming path' );
  like( $err, qr/Cerebras/, 'Cerebras streaming croak names the engine' );
  like( $err, qr/tools and response_format/,
    'Cerebras streaming croak names both conflicting fields' );
}

# --- Cerebras: tools alone -> NO croak (over-fire guard) ------------------
{
  my $engine = cerebras();
  my ( $ok, $err ) = run( sub { $engine->chat_f(
    messages => ['weather?'],
    tools    => [$TOOL],
  ) });
  ok( $ok, 'Cerebras: tools without response_format does NOT croak' )
    or diag $err;
  is( $engine->_async_http->request_count, 1,
    'Cerebras: tools-only request reached the transport' );
}

# --- Cerebras: response_format alone -> NO croak (over-fire guard) --------
{
  my $engine = cerebras();
  my ( $ok, $err ) = run( sub { $engine->chat_f(
    messages        => ['weather?'],
    response_format => $JSON_SCHEMA_RF,
  ) });
  ok( $ok, 'Cerebras: response_format without tools does NOT croak' )
    or diag $err;
  is( $engine->_async_http->request_count, 1,
    'Cerebras: response_format-only request reached the transport' );
}

# ======================================================================
# Groq — MODE-AWARE (json_schema only) + streaming exclusion
# ======================================================================

# --- Groq: tools + json_schema -> croak -----------------------------------
{
  my ( $ok, $err ) = run( sub { groq()->chat_f(
    messages        => ['weather?'],
    tools           => [$TOOL],
    response_format => $JSON_SCHEMA_RF,
  ) });
  ok( !$ok, 'Groq: tools + response_format json_schema croaks in chat_f' );
  like( $err, qr/Groq/, 'Groq json_schema+tools croak names the engine' );
  like( $err, qr/tools and response_format json_schema/,
    'Groq json_schema+tools croak names both conflicting fields' );
  like( $err, qr/400/, 'Groq json_schema+tools croak says the provider rejects it (400)' );
}

# --- Groq: tools + json_object -> NO croak (PASS-THROUGH) -----------------
# The over-fire the advisor warned about: json_object + tools is a valid Groq
# combination and must NOT be refused. Removing the mode check (json_schema
# only) would croak here and turn this red.
{
  my $engine = groq();
  my ( $ok, $err ) = run( sub { $engine->chat_f(
    messages        => ['weather?'],
    tools           => [$TOOL],
    response_format => $JSON_OBJECT_RF,
  ) });
  ok( $ok, 'Groq: tools + response_format json_object does NOT croak (allowed)' )
    or diag $err;

  is( $engine->_async_http->request_count, 1,
    'Groq: json_object+tools request reached the transport' );
  my ($request) = $engine->_async_http->requests;
  my $body = $json->decode( $request->content );
  is( $body->{response_format}{type}, 'json_object',
    'Groq: json_object response_format is still on the wire' );
  ok( ref $body->{tools} eq 'ARRAY' && @{ $body->{tools} },
    'Groq: tools are still on the wire alongside json_object' );
}

# --- Groq: json_schema + streaming -> croak (regardless of tools) ---------
{
  my ( $ok, $err ) = run( sub { groq()->chat_stream_realtime_f(
    messages        => ['weather?'],
    response_format => $JSON_SCHEMA_RF,
  ) });
  ok( !$ok, 'Groq: response_format json_schema croaks on the streaming path (no tools)' );
  like( $err, qr/Groq/, 'Groq streaming croak names the engine' );
  like( $err, qr/json_schema with streaming/,
    'Groq streaming croak names the streaming exclusion' );
  like( $err, qr/400/, 'Groq streaming croak says the provider rejects it (400)' );
}

# --- Groq: json_object + tools + streaming path -> NO exclusion croak -----
# json_object is unrestricted, so the exclusion guard must let it through even
# on the streaming path. (The mock transport does not implement the streaming
# header callback, so the request fails downstream — but crucially NOT with the
# capability-exclusion croak.)
{
  my ( $ok, $err ) = run( sub { groq()->chat_stream_realtime_f(
    messages        => ['weather?'],
    tools           => [$TOOL],
    response_format => $JSON_OBJECT_RF,
  ) });
  ok( !$ok, 'Groq: json_object streaming still fails on the mock transport' );
  unlike( $err, qr/Structured Outputs|json_schema/,
    'Groq: json_object streaming is NOT refused by the exclusion guard' );
}

# ======================================================================
# Scope is EXACTLY Cerebras + Groq — a sibling that advertises both
# tools_native and response_format_json_schema (OpenAI) inherits the base
# no-op hook and must NOT croak on tools + json_schema.
# ======================================================================
{
  my $engine = Langertha::Engine::OpenAI->new(
    api_key     => 'apikey',
    model       => 'gpt-4o-mini',
    _async_http => mock(),
  );
  can_ok( $engine, '_check_capability_exclusions' );
  my ( $ok, $err ) = run( sub { $engine->chat_f(
    messages        => ['weather?'],
    tools           => [$TOOL],
    response_format => $JSON_SCHEMA_RF,
  ) });
  ok( $ok, 'OpenAI: tools + response_format json_schema does NOT croak (base no-op)' )
    or diag $err;
}

done_testing;
