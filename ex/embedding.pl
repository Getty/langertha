#!/usr/bin/env perl
# ABSTRACT: Embedding examples

$|=1;

use utf8;
use open ':std', ':encoding(UTF-8)';
use strict;
use warnings;
use Data::Dumper;

use Langertha::Engine::Ollama;
use Langertha::Engine::OpenAI;

if ($ENV{OLLAMA_URL}) {

  my $ollama = Langertha::Engine::Ollama->new(
    url => $ENV{OLLAMA_URL},
  );

  print Dumper($ollama->simple_embedding("the"));

}

if ($ENV{OPENAI_API_KEY}) {

  my $openai = Langertha::Engine::OpenAI->new(
    api_key => $ENV{OPENAI_API_KEY},
  );

  print Dumper($openai->simple_embedding("the"));

}

exit 0;