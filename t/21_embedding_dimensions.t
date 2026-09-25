#!/usr/bin/env perl
# ABSTRACT: embedding_dimensions reaches the wire as dimensions / outputDimensionality; no translation operation
use strict;
use warnings;
use Test2::Bundle::More;
use JSON::MaybeXS;

use Langertha::Engine::OpenAI;
use Langertha::Engine::vLLM;
use Langertha::Engine::Gemini;
use Langertha::Engine::Whisper;

# karr k316 (from k309):
#  - simple_embedding / simple_embedding_f take only the text, so a shortened
#    vector (OpenAI `dimensions`, Gemini `outputDimensionality`) was reachable
#    only by building the request by hand with embedding_request. The engine
#    attribute embedding_dimensions carries it through every embedding call; a
#    per-request extra still wins over it, and unset it sends nothing, so the
#    model's native size stays the default.
#  - TranscriptionBase allowed the createTranslation operation although no
#    method builds such a request; Langertha has no translation feature, so the
#    operation is not allowed.

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);
sub body { $json->decode( $_[0]->content ) }

subtest 'OpenAI-compatible: dimensions' => sub {
  my $plain = Langertha::Engine::OpenAI->new( api_key => 'k' );
  ok !exists body( $plain->embedding('x') )->{dimensions}, 'unset: no dimensions field';

  my $openai = Langertha::Engine::OpenAI->new( api_key => 'k', embedding_dimensions => 256 );
  is $openai->embedding_dimensions, 256, 'attribute readable';
  is body( $openai->embedding('x') )->{dimensions}, 256, 'embedding() sends dimensions';
  is body( $openai->embedding([qw( a b )]) )->{dimensions}, 256, 'a batch sends it once';
  is body( $openai->embedding_request( 'x', dimensions => 64 ) )->{dimensions}, 64,
    'a per-request dimensions extra wins over the attribute';

  my $vllm = Langertha::Engine::vLLM->new( url => 'http://localhost:8000/v1', embedding_dimensions => 32 );
  is body( $vllm->embedding('x') )->{dimensions}, 32, 'any OpenAI-compatible engine sends it';
};

subtest 'Gemini: embedContentConfig.outputDimensionality' => sub {
  my $plain = Langertha::Engine::Gemini->new( api_key => 'k' );
  ok !exists body( $plain->embedding('x') )->{embedContentConfig}, 'unset: no embedContentConfig';

  my $gemini = Langertha::Engine::Gemini->new( api_key => 'k', embedding_dimensions => 768 );
  is_deeply body( $gemini->embedding('x') )->{embedContentConfig},
    { outputDimensionality => 768 }, 'single request: in embedContentConfig';
  ok !exists body( $gemini->embedding('x') )->{outputDimensionality},
    'not the deprecated top-level spelling';
  is_deeply [ map { $_->{embedContentConfig} } @{ body( $gemini->embedding([qw( a b )]) )->{requests} } ],
    [ { outputDimensionality => 768 }, { outputDimensionality => 768 } ],
    'batch: every request carries it';
  is_deeply body( $gemini->embedding_request( 'x', task_type => 'RETRIEVAL_QUERY' ) )->{embedContentConfig},
    { outputDimensionality => 768, taskType => 'RETRIEVAL_QUERY' },
    'merged with other config extras';
  is body( $gemini->embedding_request( 'x', output_dimensionality => 128 ) )
    ->{embedContentConfig}{outputDimensionality}, 128, 'output_dimensionality extra wins';
  is body( $gemini->embedding_request( 'x', embedContentConfig => { outputDimensionality => 64 } ) )
    ->{embedContentConfig}{outputDimensionality}, 64, 'a caller embedContentConfig wins';
};

subtest 'TranscriptionBase: no translation operation' => sub {
  my $whisper = Langertha::Engine::Whisper->new( url => 'http://localhost:8000/v1' );
  ok $whisper->can_operation('createTranscription'), 'transcription allowed';
  ok !$whisper->can_operation('createTranslation'), 'translation not allowed';
  my $handle = Langertha::Engine::OpenAI->new( api_key => 'k' )->whisper;
  ok !$handle->can_operation('createTranslation'), 'nor on the OpenAI whisper handle';
};

done_testing;
