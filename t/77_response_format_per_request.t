#!/usr/bin/env perl
# ABSTRACT: Per-request response_format must reach the wire on Anthropic, Ollama and Gemini

# karr #45: AnthropicBase::_translate_response_format and Ollama::chat_request
# read only the engine attribute and never looked at %extra, so a per-request
# response_format handed in via chat_f stayed untranslated. On Anthropic it then
# leaked onto the Messages wire as a top-level response_format (HTTP 400); on
# Ollama it was a silent no-op. Precedence is per-request beats per-engine.
#
# karr #48: Gemini::chat_request had the identical defect — a per-request
# response_format landed as a top-level "response_format" on the generateContent
# body while generationConfig.responseSchema stayed empty.

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;
use HTTP::Response;

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

sub wire {
  my ( $engine, %extra ) = @_;
  return $json->decode(
    $engine->chat_request( $engine->chat_messages('testprompt'), %extra )->content
  );
}

# --- Anthropic: per-request json_schema (NATIVE output_config.format) ----
# k133 / ADR 0005 amendment: the first-party Claude Messages API has native
# structured output. Engine::Anthropic emits it as output_config.format instead
# of the legacy synthesized-tool + forced tool_choice rewrite — no tools,
# no tool_choice, no 400 on Fable/Mythos 5.1 (which reject forced tool use).
# Sabotage check: revert _native_structured_output to 0 and these go red
# (tools/tool_choice reappear, output_config.format vanishes).
{
  my $data = wire( anthropic(), response_format => {
    type        => 'json_schema',
    json_schema => { name => 'extract', description => 'extractor', schema => $SCHEMA },
  });

  ok( !exists $data->{response_format},
    'Anthropic: per-request response_format is consumed, not passed to the wire' );
  is_deeply( $data->{output_config}{format}, { type => 'json_schema', schema => $SCHEMA },
    'Anthropic: per-request json_schema becomes native output_config.format' );
  ok( !exists $data->{tools} && !exists $data->{tool_choice},
    'Anthropic: native structured output injects no synthesized tool / tool_choice' );
}

# --- Anthropic: per-request json_object (open-object native schema) -------
{
  my $data = wire( anthropic(), response_format => { type => 'json_object' } );

  ok( !exists $data->{response_format},
    'Anthropic: per-request json_object is consumed, not passed to the wire' );
  is_deeply( $data->{output_config}{format},
    { type => 'json_schema', schema => { type => 'object', additionalProperties => JSON->true } },
    'Anthropic: json_object maps onto an open-object native json_schema' );
  ok( !exists $data->{tools} && !exists $data->{tool_choice},
    'Anthropic: json_object native output injects no synthesized tool' );
}

# --- Anthropic: output_config.effort and .format MERGE, never clobber -----
# k133 point 3: Langertha::Reasoning::to_anthropic already owns output_config
# for reasoning effort. Native structured output must fold format INTO that
# hash, not replace it. Sabotage check: make _merge_output_config_format
# overwrite instead of merge and effort disappears here.
{
  my $data = wire(
    anthropic( reasoning_effort => 'high' ),
    response_format => {
      type        => 'json_schema',
      json_schema => { name => 'extract', schema => $SCHEMA },
    },
  );

  is( $data->{output_config}{effort}, 'high',
    'Anthropic: output_config.effort survives alongside .format (merged, not clobbered)' );
  is_deeply( $data->{output_config}{format}, { type => 'json_schema', schema => $SCHEMA },
    'Anthropic: output_config.format is present alongside .effort' );
}

# --- Anthropic: per-request beats the engine attribute ------------------
{
  my $engine = anthropic( response_format => {
    type        => 'json_schema',
    json_schema => { name => 'engine_level', schema => $OTHER_SCHEMA },
  });
  my $data = wire( $engine, response_format => {
    type        => 'json_schema',
    json_schema => { name => 'per_request', schema => $SCHEMA },
  });

  is_deeply( $data->{output_config}{format}, { type => 'json_schema', schema => $SCHEMA },
    'Anthropic: per-request response_format wins over the engine attribute' );
}

# --- Anthropic: engine attribute alone still works ----------------------
{
  my $data = wire( anthropic( response_format => {
    type        => 'json_schema',
    json_schema => { name => 'engine_level', schema => $OTHER_SCHEMA },
  }));

  is_deeply( $data->{output_config}{format}, { type => 'json_schema', schema => $OTHER_SCHEMA },
    'Anthropic: engine-attribute response_format still translates to output_config.format' );
}

# --- Anthropic: the native structured payload arrives as Response.content -
# ADR 0005 paragraph 3 asks every structured-output path to land the payload
# the same way. Native structured output emits the JSON as an ordinary text
# block, so chat_response's existing text join puts it in Response.content with
# no tool_use lift needed (like Gemini's responseSchema below).
{
  my $engine  = anthropic();
  my $request = $engine->chat_request( $engine->chat_messages('testprompt'),
    response_format => {
      type        => 'json_schema',
      json_schema => { name => 'extract', schema => $SCHEMA },
    },
  );

  my $http = HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'application/json' ],
    $json->encode({
      id      => 'msg_1',
      model   => 'claude-x',
      content => [ {
        type => 'text',
        text => '{"city":"Wiesbaden"}',
      } ],
    })
  );

  my $response = $request->response_call->($http);
  my $structured = eval { $json->decode( $response->content ) };
  is_deeply( $structured, { city => 'Wiesbaden' },
    'Anthropic: native structured output arrives as Response.content JSON' );
}

# --- Ollama: per-request json_schema ------------------------------------
{
  my $data = wire( ollama(), response_format => {
    type        => 'json_schema',
    json_schema => { name => 'extract', schema => $SCHEMA },
  });

  ok( !exists $data->{response_format},
    'Ollama: per-request response_format is consumed, not passed to the wire' );
  is_deeply( $data->{format}, $SCHEMA,
    'Ollama: per-request json_schema becomes the format schema' );
}

# --- Ollama: per-request json_object ------------------------------------
{
  my $data = wire( ollama(), response_format => { type => 'json_object' } );

  ok( !exists $data->{response_format},
    'Ollama: per-request json_object is consumed, not passed to the wire' );
  is( $data->{format}, 'json', 'Ollama: per-request json_object becomes format=json' );
}

# --- Ollama: per-request beats engine attribute and json_format ---------
{
  my $engine = ollama(
    json_format     => 1,
    response_format => { type => 'json_object' },
  );
  my $data = wire( $engine, response_format => {
    type        => 'json_schema',
    json_schema => { name => 'extract', schema => $SCHEMA },
  });

  is_deeply( $data->{format}, $SCHEMA,
    'Ollama: per-request response_format wins over engine attribute and json_format' );
}

# --- Ollama: engine attribute alone still works -------------------------
{
  my $data = wire( ollama( response_format => {
    type        => 'json_schema',
    json_schema => { name => 'engine_level', schema => $OTHER_SCHEMA },
  }));

  is_deeply( $data->{format}, $OTHER_SCHEMA,
    'Ollama: engine-attribute response_format still translates' );

  my $legacy = wire( ollama( json_format => 1 ) );
  is( $legacy->{format}, 'json', 'Ollama: legacy json_format attribute still works' );
}

# --- Gemini: per-request json_schema ------------------------------------
{
  my $data = wire( gemini(), response_format => {
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

# --- Gemini: per-request json_object ------------------------------------
{
  my $data = wire( gemini(), response_format => { type => 'json_object' } );

  ok( !exists $data->{response_format},
    'Gemini: per-request json_object is consumed, not passed to the wire' );
  is( $data->{generationConfig}{responseMimeType}, 'application/json',
    'Gemini: per-request json_object sets responseMimeType' );
  ok( !exists $data->{generationConfig}{responseSchema},
    'Gemini: json_object leaves responseSchema unset' );
}

# --- Gemini: per-request beats the engine attribute ---------------------
{
  my $engine = gemini( response_format => {
    type        => 'json_schema',
    json_schema => { name => 'engine_level', schema => $OTHER_SCHEMA },
  });
  my $data = wire( $engine, response_format => {
    type        => 'json_schema',
    json_schema => { name => 'per_request', schema => $SCHEMA },
  });

  is_deeply( $data->{generationConfig}{responseSchema}, $SCHEMA,
    'Gemini: per-request response_format wins over the engine attribute' );
}

# --- Gemini: engine attribute alone still works -------------------------
{
  my $data = wire( gemini( response_format => {
    type        => 'json_schema',
    json_schema => { name => 'engine_level', schema => $OTHER_SCHEMA },
  }));

  is_deeply( $data->{generationConfig}{responseSchema}, $OTHER_SCHEMA,
    'Gemini: engine-attribute response_format still translates' );
}

# --- Gemini: the structured payload converges on Response.content -------
# ADR 0005 paragraph 3 asks every structured-output path to land the payload
# the same way. Gemini needs no counterpart to the Anthropic tool_use lift:
# responseSchema makes the model emit the JSON as an ordinary text part, so
# chat_response's existing text join already puts it in Response.content.
{
  my $engine  = gemini();
  my $request = $engine->chat_request( $engine->chat_messages('testprompt'),
    response_format => {
      type        => 'json_schema',
      json_schema => { name => 'extract', schema => $SCHEMA },
    },
  );

  my $http = HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'application/json' ],
    $json->encode({
      modelVersion => 'gemini-3-flash-preview',
      candidates   => [ {
        finishReason => 'STOP',
        content      => { role => 'model', parts => [
          { text => '{"city":"Wiesbaden"}' },
        ] },
      } ],
    })
  );

  my $response = $request->response_call->($http);
  my $structured = eval { $json->decode( $response->content ) };
  is_deeply( $structured, { city => 'Wiesbaden' },
    'Gemini: per-request structured output arrives as Response.content JSON' );
}

done_testing;
