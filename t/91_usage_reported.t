#!/usr/bin/env perl
# ABSTRACT: Usage tells an unreported input/output count from a reported zero; OTLP leaves unreported counts out

use strict;
use warnings;

use Test2::Bundle::More;

use Langertha::Usage;
use Langertha::Response;
use Langertha::Trace::OTLP;

# Usage keeps input_tokens / output_tokens numeric (0 when the wire had no
# count) for callers that add up. has_input_tokens / has_output_tokens say
# whether that number was reported. The OTLP export must leave an unreported
# count out instead of sending gen_ai.usage.*_tokens = 0, and must still send a
# reported 0.

my $OTLP = 'Langertha::Trace::OTLP';

sub flags {
  my ($u) = @_;
  return [ $u->has_input_tokens, $u->has_output_tokens, $u->has_total_tokens ];
}

subtest 'new' => sub {
  my $u = Langertha::Usage->new;
  is_deeply( flags($u), [ 0, 0, 0 ], 'empty: nothing reported' );
  is( $u->input_tokens,  0, 'input still numeric 0' );
  is( $u->output_tokens, 0, 'output still numeric 0' );
  is( $u->total_tokens,  0, 'total still numeric 0' );

  $u = Langertha::Usage->new( input_tokens => 0, output_tokens => 0 );
  is_deeply( flags($u), [ 1, 1, 1 ], 'explicit zeros are reported' );

  $u = Langertha::Usage->new( input_tokens => 5 );
  is_deeply( flags($u), [ 1, 0, 0 ], 'input only: total is a sum with an unreported half' );

  $u = Langertha::Usage->new( total_tokens => 9 );
  is_deeply( flags($u), [ 0, 0, 1 ], 'total only' );
};

subtest 'from_hash: OpenAI shape' => sub {
  my $u = Langertha::Usage->from_hash( { prompt_tokens => 10, completion_tokens => 3, total_tokens => 13 } );
  is_deeply( flags($u), [ 1, 1, 1 ], 'full block' );

  $u = Langertha::Usage->from_hash( {} );
  is_deeply( flags($u), [ 0, 0, 0 ], 'empty block' );

  $u = Langertha::Usage->from_hash( { total_tokens => 42 } );
  is_deeply( flags($u), [ 0, 0, 1 ], 'only total_tokens' );
  is( $u->total_tokens, 42, 'total kept' );
  is( $u->input_tokens, 0, 'input reads 0' );

  $u = Langertha::Usage->from_hash( { prompt_tokens => 0, completion_tokens => 0 } );
  is_deeply( flags($u), [ 1, 1, 1 ], 'reported zeros' );

  $u = Langertha::Usage->from_hash( { prompt_tokens => 7, prompt_tokens_details => { cached_tokens => 4 } } );
  is_deeply( flags($u), [ 1, 0, 0 ], 'prompt only, with cache details' );
};

subtest 'from_hash: Anthropic shape' => sub {
  my $u = Langertha::Usage->from_hash( { input_tokens => 3, output_tokens => 9,
    cache_read_input_tokens => 100 } );
  is_deeply( flags($u), [ 1, 1, 1 ], 'full block' );

  $u = Langertha::Usage->from_hash( { cache_read_input_tokens => 100, cache_creation_input_tokens => 20 } );
  is_deeply( flags($u), [ 0, 0, 0 ], 'only cache counts' );
  is( $u->cached_tokens, 100, 'cache read kept' );
};

subtest 'from_hash: Gemini shape' => sub {
  my $u = Langertha::Usage->from_hash( { promptTokenCount => 8, candidatesTokenCount => 2, totalTokenCount => 10 } );
  is_deeply( flags($u), [ 1, 1, 1 ], 'full block' );

  # proto3 JSON omits a zero count: inside a Gemini block, missing means 0.
  $u = Langertha::Usage->from_hash( { promptTokenCount => 8, totalTokenCount => 8 } );
  is_deeply( flags($u), [ 1, 1, 1 ], 'no candidatesTokenCount: output reported' );
  is( $u->output_tokens, 0, 'missing candidatesTokenCount is a reported 0' );

  $u = Langertha::Usage->from_hash( { totalTokenCount => 8 } );
  is_deeply( flags($u), [ 1, 1, 1 ], 'only totalTokenCount: both counts reported' );
  is_deeply( [ $u->input_tokens, $u->output_tokens, $u->total_tokens ], [ 0, 0, 8 ], 'counts 0, total kept' );

  $u = Langertha::Usage->from_hash( { promptTokenCount => 8, thoughtsTokenCount => 5 } );
  is_deeply( [ $u->has_output_tokens, $u->output_tokens ], [ 1, 5 ], 'thoughts alone report output' );
};

subtest 'Gemini engine: zero counts omitted inside usageMetadata' => sub {
  require Langertha::Engine::Gemini;
  require HTTP::Response;
  require JSON::MaybeXS;
  my $engine = Langertha::Engine::Gemini->new( api_key => 'k', model => 'gemini-2.5-flash' );
  my $answer = sub {
    my (%extra) = @_;
    my $http = HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'application/json' ],
      JSON::MaybeXS->new( utf8 => 1 )->encode( {
        promptFeedback => { blockReason => 'SAFETY' }, modelVersion => 'gemini-2.5-flash', %extra,
      } ) );
    return $engine->chat_response($http);
  };

  my $resp = $answer->( usageMetadata => { promptTokenCount => 8, totalTokenCount => 8 } );
  is_deeply( flags( $resp->usage ), [ 1, 1, 1 ], 'blocked prompt: output reported' );
  is( $resp->usage->output_tokens, 0, 'output 0' );
  is( $resp->usage->{completion_tokens}, 0, 'completion_tokens key is 0' );

  $resp = $answer->( usageMetadata => { totalTokenCount => 8 } );
  is_deeply( flags( $resp->usage ), [ 1, 1, 1 ], 'only totalTokenCount: both reported' );
  is_deeply( [ $resp->usage->input_tokens, $resp->usage->output_tokens ], [ 0, 0 ], 'both 0' );

  $resp = $answer->();
  ok( !$resp->has_usage, 'no usageMetadata: no usage on the Response' );
  is_deeply( flags( Langertha::Usage->from_response($resp) ), [ 0, 0, 0 ], 'no usageMetadata: nothing reported' );
};

subtest 'Gemini stream: an empty usageMetadata reports zeros, as from_raw does' => sub {
  require Langertha::Engine::Gemini;
  my $engine = Langertha::Engine::Gemini->new( api_key => 'k', model => 'gemini-2.5-flash' );
  my %chunk = (
    'answer chunk'  => { candidates => [ { content => { parts => [ { text => 'hi' } ] }, finishReason => 'STOP' } ],
                         usageMetadata => {} },
    'blocked chunk' => { promptFeedback => { blockReason => 'SAFETY' }, usageMetadata => {} },
  );
  is_deeply( flags( Langertha::Usage->from_raw( { usageMetadata => {} } ) ), [ 1, 1, 1 ],
    'from_raw: the reference' );
  for my $name ( sort keys %chunk ) {
    my $chunk = $engine->parse_stream_chunk( $chunk{$name} );
    ok( $chunk->has_usage, "$name: carries usage" );
    my $resp = $engine->_stream_response( [$chunk], {} );
    is_deeply( flags( $resp->usage ), [ 1, 1, 1 ], "$name: every count reported" );
    is_deeply( [ map { $resp->usage->$_ } qw( input_tokens output_tokens total_tokens ) ], [ 0, 0, 0 ],
      "$name: all 0" );
  }

  my $um = { promptTokenCount => 4, candidatesTokenCount => 1, totalTokenCount => 5 };
  my $chunk = $engine->parse_stream_chunk( { %{ $chunk{'answer chunk'} }, usageMetadata => $um } );
  is( $chunk->usage, $um, 'a non-empty usageMetadata is passed as sent' );
  ok( !$engine->parse_stream_chunk( { candidates => [ { content => { parts => [ { text => 'x' } ] } } ] } )->has_usage,
    'no usageMetadata: no usage on the chunk' );
};

subtest 'from_raw: Ollama and AKI native' => sub {
  my $u = Langertha::Usage->from_raw( { prompt_eval_count => 12 } );
  is_deeply( flags($u), [ 1, 0, 0 ], 'Ollama: only prompt_eval_count' );

  $u = Langertha::Usage->from_raw( { prompt_eval_count => 12, eval_count => 4 } );
  is_deeply( flags($u), [ 1, 1, 1 ], 'Ollama: both counts' );

  $u = Langertha::Usage->from_raw( { num_cached_tokens => 16 } );
  is_deeply( flags($u), [ 0, 0, 0 ], 'AKI: only the cache count' );
  is( $u->cached_tokens, 16, 'AKI cache count kept' );

  $u = Langertha::Usage->from_raw( { prompt_length => 30, num_generated_tokens => 0 } );
  is_deeply( flags($u), [ 1, 1, 1 ], 'AKI: a reported zero output is reported' );
  is( $u->output_tokens, 0, 'AKI zero output' );

  $u = Langertha::Usage->from_raw( { prompt_length => 30 } );
  is_deeply( flags($u), [ 1, 0, 0 ], 'AKI: only prompt_length' );
};

subtest 'from_raw: usage block, usageMetadata, response envelope' => sub {
  my $u = Langertha::Usage->from_raw( { usage => { total_tokens => 5 } } );
  is_deeply( flags($u), [ 0, 0, 1 ], 'usage block with only a total' );

  $u = Langertha::Usage->from_raw( { usageMetadata => { promptTokenCount => 4 } } );
  is_deeply( flags($u), [ 1, 1, 1 ], 'usageMetadata with only a prompt count: output a reported 0' );
  is( $u->output_tokens, 0, 'output 0' );

  $u = Langertha::Usage->from_raw( { usageMetadata => { totalTokenCount => 8 } } );
  is_deeply( flags($u), [ 1, 1, 1 ], 'usageMetadata with only totalTokenCount' );
  is( $u->output_tokens, 0, 'output 0' );

  $u = Langertha::Usage->from_raw( { usageMetadata => {} } );
  is_deeply( flags($u), [ 1, 1, 1 ], 'empty usageMetadata block: every count a reported 0' );

  is( Langertha::Usage->from_raw( { candidates => [] } ), undef, 'no usageMetadata: no usage' );

  $u = Langertha::Usage->from_raw( { response => { usage => { input_tokens => 1, output_tokens => 0 } } } );
  is_deeply( flags($u), [ 1, 1, 1 ], 'Responses envelope with a reported zero output' );
};

subtest 'Response coerces with the flags' => sub {
  my $r = Langertha::Response->new( content => 'x', usage => { total_tokens => 3 } );
  is_deeply( flags( $r->usage ), [ 0, 0, 1 ], 'Response usage keeps the flags' );
  is( $r->usage->{total_tokens}, 3, 'hash overload unchanged' );
};

subtest 'merge' => sub {
  my $none = Langertha::Usage->new;
  my $in   = Langertha::Usage->new( input_tokens => 5 );
  my $both = Langertha::Usage->new( input_tokens => 2, output_tokens => 3 );
  is_deeply( flags( $none->merge($none) ), [ 0, 0, 0 ], 'neither side reported' );
  is_deeply( flags( $none->merge($in) ),   [ 1, 0, 0 ], 'one side reported input' );
  my $sum = $in->merge($both);
  is_deeply( flags($sum), [ 1, 1, 1 ], 'either side reported each' );
  is_deeply( [ $sum->input_tokens, $sum->output_tokens ], [ 7, 3 ], 'sums unchanged' );
};

subtest 'usage_attributes leaves unreported counts out' => sub {
  my %u = $OTLP->usage_attributes( Langertha::Usage->from_hash( {} ) );
  is_deeply( \%u, {}, 'nothing reported: no attributes' );

  %u = $OTLP->usage_attributes( Langertha::Usage->from_hash( { total_tokens => 42 } ) );
  is_deeply( \%u, {}, 'only a total: no input/output attributes' );

  %u = $OTLP->usage_attributes( Langertha::Usage->from_hash( { prompt_tokens => 10 } ) );
  is_deeply( \%u, { 'gen_ai.usage.input_tokens' => 10 }, 'input only' );

  %u = $OTLP->usage_attributes( Langertha::Usage->from_hash( { completion_tokens => 4 } ) );
  is_deeply( \%u, { 'gen_ai.usage.output_tokens' => 4 }, 'output only' );

  %u = $OTLP->usage_attributes( Langertha::Usage->from_hash( { prompt_tokens => 0, completion_tokens => 0 } ) );
  is_deeply( \%u, { 'gen_ai.usage.input_tokens' => 0, 'gen_ai.usage.output_tokens' => 0 },
    'reported zeros are sent' );

  %u = $OTLP->usage_attributes( Langertha::Usage->from_raw( { prompt_length => 30, num_generated_tokens => 0 } ) );
  is_deeply( \%u, { 'gen_ai.usage.input_tokens' => 30, 'gen_ai.usage.output_tokens' => 0 },
    'AKI native reported zero output is sent' );

  # Anthropic spelling (cache beside the input) without an input count: the
  # cache counts are sent on their own attributes, but not folded into a
  # stand-in input count.
  %u = $OTLP->usage_attributes( Langertha::Usage->from_hash( { output_tokens => 9,
    cache_read_input_tokens => 100, cache_creation_input_tokens => 20 } ) );
  is_deeply( \%u, {
    'gen_ai.usage.output_tokens'               => 9,
    'gen_ai.usage.cache_read.input_tokens'     => 100,
    'gen_ai.usage.cache_creation.input_tokens' => 20,
  }, 'no input: cache not folded into a fake input' );

  # With the input reported, the fold still happens.
  %u = $OTLP->usage_attributes( Langertha::Usage->from_hash( { input_tokens => 3, output_tokens => 9,
    cache_read_input_tokens => 100, cache_creation_input_tokens => 20 } ) );
  is( $u{'gen_ai.usage.input_tokens'}, 123, 'reported Anthropic input: cache folded in' );
};

done_testing;
