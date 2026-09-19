#!/usr/bin/env perl
# ABSTRACT: Model-scoped capability exclusion + aggregator transitivity (karr #148)

# karr #148 generalizes the per-ENGINE capability-exclusion croak (ADR 0021)
# to a per-MODEL seam (Langertha::Role::Chat::model_capability_exclusions). The
# tools + json_schema mutual exclusion is a property of the MODEL (gpt-oss-120b
# and similar constrained-decoding stacks), not the engine, so it must:
#
#   (1) travel with the model — the shared rule lives on Langertha::Engine::
#       OpenAIBase and every OpenAI-dialect engine inherits it, keyed on
#       chat_model. A model that excludes (gpt-oss-120b) and a sibling that does
#       not (llama-3.3-70b) on the SAME engine get opposite treatment.
#   (2) catch AGGREGATOR routes — TSystems / AKIOpenAI DEFAULT to gpt-oss-120b,
#       and OpenRouter / HuggingFace / Replicate reach it through a
#       `provider/gpt-oss-...` id. All must croak on tools + json_schema without
#       any per-engine plumbing, because the regex matcher catches the routed
#       backend id.
#
# The shared rule is json_schema-ONLY (constrained decoding = grammar). The
# stricter json_object refusal is a Cerebras platform quirk and stays on
# Cerebras's own override — so an aggregator serving gpt-oss with json_object +
# tools must NOT be refused by the inherited rule.
#
# All cases are MOCKED — no live API calls. Sabotage check: remove the
# OpenAIBase rule (or the regex matcher) and the aggregator/model-scoped croaks
# stop firing, turning the exclusion-message assertions red; the requests then
# reach the mock instead.

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;

use lib 't/lib';
use Test::MockAsyncHTTP;

use Langertha::Engine::TSystems;
use Langertha::Engine::AKIOpenAI;
use Langertha::Engine::OpenRouter;
use Langertha::Engine::HuggingFace;
use Langertha::Engine::Cerebras;
use Langertha::Engine::Groq;

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
# a rule is removed (sabotage check stays offline).
sub mock {
  return Test::MockAsyncHTTP->new( responses => [
    Test::MockAsyncHTTP->mock_json_response({
      model   => 'gpt-oss-120b',
      choices => [{ message => { role => 'assistant', content => 'ok' } }],
    }),
  ]);
}

# Run a coderef that returns a Future and report ($ok, $err).
sub run {
  my ($code) = @_;
  my $ok = eval { $code->()->get; 1 };
  return ( $ok, $@ );
}

# ======================================================================
# (2) AGGREGATOR-DEFAULT — TSystems and AKIOpenAI DEFAULT to gpt-oss-120b,
# so the exclusion is inherited from OpenAIBase and fires with no per-engine
# code. This is the transitivity headline: neither engine has any exclusion
# code of its own.
# ======================================================================
for my $case (
  [ 'TSystems'  => sub { Langertha::Engine::TSystems->new(@_) } ],
  [ 'AKIOpenAI' => sub { Langertha::Engine::AKIOpenAI->new(@_) } ],
) {
  my ( $name, $ctor ) = @$case;

  # Default model (gpt-oss-120b) + tools + json_schema -> croak.
  {
    my $engine = $ctor->( api_key => 'apikey', _async_http => mock() );
    is( $engine->chat_model, 'gpt-oss-120b',
      "$name default model is gpt-oss-120b (the aggregator default)" );
    my ( $ok, $err ) = run( sub { $engine->chat_f(
      messages        => ['weather?'],
      tools           => [$TOOL],
      response_format => $JSON_SCHEMA_RF,
    ) });
    ok( !$ok, "$name (default gpt-oss-120b): tools + json_schema croaks (inherited)" );
    like( $err, qr/\Q$name\E/, "$name croak names the engine" );
    like( $err, qr/gpt-oss-120b/, "$name croak names the constrained model" );
    like( $err, qr/400/, "$name croak says the provider rejects it (400)" );
    is( $engine->_async_http->request_count, 0,
      "$name: the conflicting request never reached the transport" );
  }

  # (1) SIBLING model on the SAME engine that does NOT exclude -> no croak.
  {
    my $engine = $ctor->( api_key => 'apikey', model => 'llama-3.3-70b', _async_http => mock() );
    my ( $ok, $err ) = run( sub { $engine->chat_f(
      messages        => ['weather?'],
      tools           => [$TOOL],
      response_format => $JSON_SCHEMA_RF,
    ) });
    ok( $ok, "$name (llama-3.3-70b sibling): tools + json_schema does NOT croak" )
      or diag $err;
    is( $engine->_async_http->request_count, 1,
      "$name: the sibling-model request reached the transport" );
  }

  # The shared rule is json_schema-ONLY: gpt-oss + tools + json_object is NOT
  # refused by the inherited rule (Cerebras's stricter json_object refusal does
  # not travel to the aggregators).
  {
    my $engine = $ctor->( api_key => 'apikey', _async_http => mock() );
    my ( $ok, $err ) = run( sub { $engine->chat_f(
      messages        => ['weather?'],
      tools           => [$TOOL],
      response_format => $JSON_OBJECT_RF,
    ) });
    ok( $ok, "$name (gpt-oss-120b): tools + json_object does NOT croak (json_schema-only rule)" )
      or diag $err;
    is( $engine->_async_http->request_count, 1,
      "$name: the json_object request reached the transport" );
  }
}

# ======================================================================
# (2) AGGREGATOR-ROUTE — a passthrough aggregator reaches gpt-oss through a
# `provider/gpt-oss-...` id. The regex matcher catches the routed backend id,
# so the exclusion fires; a non-gpt-oss route on the same engine does not.
# ======================================================================
for my $case (
  [ 'OpenRouter'  => sub { Langertha::Engine::OpenRouter->new(@_) } ],
  [ 'HuggingFace' => sub { Langertha::Engine::HuggingFace->new(@_) } ],
) {
  my ( $name, $ctor ) = @$case;

  {
    my $engine = $ctor->( api_key => 'apikey', model => 'openai/gpt-oss-120b', _async_http => mock() );
    my ( $ok, $err ) = run( sub { $engine->chat_f(
      messages        => ['weather?'],
      tools           => [$TOOL],
      response_format => $JSON_SCHEMA_RF,
    ) });
    ok( !$ok, "$name (route openai/gpt-oss-120b): tools + json_schema croaks (transitive)" );
    like( $err, qr/\Q$name\E/, "$name route croak names the engine" );
    like( $err, qr{openai/gpt-oss-120b}, "$name route croak names the routed model id" );
    is( $engine->_async_http->request_count, 0,
      "$name: the conflicting routed request never reached the transport" );
  }

  {
    my $engine = $ctor->( api_key => 'apikey', model => 'meta-llama/llama-3.3-70b-instruct', _async_http => mock() );
    my ( $ok, $err ) = run( sub { $engine->chat_f(
      messages        => ['weather?'],
      tools           => [$TOOL],
      response_format => $JSON_SCHEMA_RF,
    ) });
    ok( $ok, "$name (route meta-llama/...): tools + json_schema does NOT croak" )
      or diag $err;
    is( $engine->_async_http->request_count, 1,
      "$name: the non-gpt-oss routed request reached the transport" );
  }
}

# ======================================================================
# ENGINE-vs-MODEL contrast on json_object: the SAME model (gpt-oss-120b) is
# refused with json_object + tools on Cerebras (its stricter platform rule)
# but NOT on the aggregators (the inherited json_schema-only rule). Proves the
# migrated Cerebras behavior and that the model-intrinsic rule is the common
# denominator, not the strictest reading.
# ======================================================================
{
  my $cerebras = Langertha::Engine::Cerebras->new(
    api_key => 'apikey', model => 'gpt-oss-120b', _async_http => mock() );
  my ( $ok, $err ) = run( sub { $cerebras->chat_f(
    messages        => ['weather?'],
    tools           => [$TOOL],
    response_format => $JSON_OBJECT_RF,
  ) });
  ok( !$ok, 'Cerebras (gpt-oss-120b): tools + json_object still croaks (stricter platform rule, migrated)' );
  like( $err, qr/Cerebras/, 'Cerebras json_object croak names the engine' );
  like( $err, qr/tools and response_format/, 'Cerebras json_object croak names both fields' );

  my $tsi = Langertha::Engine::TSystems->new(
    api_key => 'apikey', model => 'gpt-oss-120b', _async_http => mock() );
  my ( $ok2, $err2 ) = run( sub { $tsi->chat_f(
    messages        => ['weather?'],
    tools           => [$TOOL],
    response_format => $JSON_OBJECT_RF,
  ) });
  ok( $ok2, 'TSystems (gpt-oss-120b): tools + json_object does NOT croak (json_object is not constrained decoding)' )
    or diag $err2;
}

# ======================================================================
# GROQ platform rule (karr #184): Groq 400s a JSON response_format combined with
# tools -- BOTH json_object and json_schema, with the same "json mode cannot be
# combined with tool/function calling" message (live-verified 2026-09-19). Its
# qr// all-models override REPLACES the inherited gpt-oss json_schema-only rule,
# so unlike the aggregators above, Groq refuses json_object + tools too. A
# json_object request WITHOUT tools still reaches the wire.
#
# Sabotage check: narrow the has_tools branch of
# _exclude_json_schema_with_tools_or_streaming back to json_schema-only and the
# "json_object + tools croaks" assertion goes red (the request reaches the mock).
# ======================================================================
{
  # json_schema + tools -> croak (unchanged behavior).
  my $g1 = Langertha::Engine::Groq->new(
    api_key => 'apikey', model => 'llama-3.3-70b-versatile', _async_http => mock() );
  my ( $ok1, $err1 ) = run( sub { $g1->chat_f(
    messages        => ['weather?'],
    tools           => [$TOOL],
    response_format => $JSON_SCHEMA_RF,
  ) });
  ok( !$ok1, 'Groq: tools + json_schema still croaks' );
  like( $err1, qr/Groq/, 'Groq json_schema croak names the engine' );
  is( $g1->_async_http->request_count, 0,
    'Groq: the json_schema + tools request never reached the transport' );

  # json_object + tools -> croak (the #184 fix: Groq 400s json mode + tools too).
  my $g2 = Langertha::Engine::Groq->new(
    api_key => 'apikey', model => 'llama-3.3-70b-versatile', _async_http => mock() );
  my ( $ok2, $err2 ) = run( sub { $g2->chat_f(
    messages        => ['weather?'],
    tools           => [$TOOL],
    response_format => $JSON_OBJECT_RF,
  ) });
  ok( !$ok2, 'Groq: tools + json_object now croaks (Groq rejects json mode + tools, #184)' );
  like( $err2, qr/Groq/, 'Groq json_object croak names the engine' );
  like( $err2, qr/tool/, 'Groq json_object croak mentions the tool conflict' );
  is( $g2->_async_http->request_count, 0,
    'Groq: the json_object + tools request never reached the transport' );

  # json_object WITHOUT tools -> passes through (the rule only fires with tools).
  my $g3 = Langertha::Engine::Groq->new(
    api_key => 'apikey', model => 'llama-3.3-70b-versatile', _async_http => mock() );
  my ( $ok3, $err3 ) = run( sub { $g3->chat_f(
    messages        => ['weather?'],
    response_format => $JSON_OBJECT_RF,
  ) });
  ok( $ok3, 'Groq: json_object WITHOUT tools does NOT croak' ) or diag $err3;
  is( $g3->_async_http->request_count, 1,
    'Groq: the json_object-only request reached the transport' );
}

done_testing;
