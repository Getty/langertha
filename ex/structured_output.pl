#!/usr/bin/env perl
# ABSTRACT: OpenAI/Ollama Structured Output

$|=1;

use FindBin;
use lib "$FindBin::Bin/../lib";

use utf8;
use open ':std', ':encoding(UTF-8)';
use strict;
use warnings;
use Data::Dumper;
use JSON::MaybeXS;
use Carp qw( croak );
use DDP;

use Langertha::Engine::Ollama;
use Langertha::Engine::OpenAI;

my $jsonschema = {
  type => 'object',
  properties => {
    activities => {
      type => 'array',
      items => {
        type => 'object',
        properties => {
          time => {
            type => 'integer',
            #description => 'Time in minutes',
          },
          action => {
            type => 'string',
            #description => 'Action to be done',
          },
        },
        required => ['time','action'],
        additionalProperties => JSON->false,
      },
    },
  },
  required => [qw( activities )],
  additionalProperties => JSON->false,
};

my $prompt = <<"__EOP__";

I want to improve my cardio fitness. Help me set up a training plan. I enjoy running and occasionally cycling.
I am a beginner and have about 60 minutes three times a week.

__EOP__

{
  if ($ENV{OLLAMA_URL}) {
    my $start = time;

    my $ollama = Langertha::Engine::Ollama->new(
      model => 'llama3.1:8b',
      url => $ENV{OLLAMA_URL},
    );

    my $structured = $ollama->openai( response_format => {
      type => "json_schema",
      json_schema => {
        name => "training",
        schema => $jsonschema,
        strict => JSON->true,
      },
    });

    my $result = $structured->simple_chat($prompt.' Respond in JSON.');

    eval {
      my $res = JSON::MaybeXS->new->utf8->decode($result);
      print Dumper $res;
    };
    if ($@) {
      print Dumper $result;
    }

    my $end = time;
    printf("\n\n%u\n\n", $end - $start);
  }
}

exit 0;