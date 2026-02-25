#!/usr/bin/env perl
# ABSTRACT: Live integration test for embedding APIs with semantic similarity

use strict;
use warnings;

use Test2::Bundle::More;

BEGIN {
  my @available;
  push @available, 'openai'  if $ENV{TEST_LANGERTHA_OPENAI_API_KEY};
  push @available, 'mistral' if $ENV{TEST_LANGERTHA_MISTRAL_API_KEY};
  push @available, 'ollama'      if $ENV{TEST_LANGERTHA_OLLAMA_URL};
  push @available, 'ollamaopenai' if $ENV{TEST_LANGERTHA_OLLAMA_URL};
  push @available, 'llamacpp'    if $ENV{TEST_LANGERTHA_LLAMACPP_URL};
  unless (@available) {
    plan skip_all => 'Set TEST_LANGERTHA_OPENAI_API_KEY, TEST_LANGERTHA_MISTRAL_API_KEY, TEST_LANGERTHA_OLLAMA_URL, or TEST_LANGERTHA_LLAMACPP_URL';
  }
  eval { require Math::Vector::Similarity; Math::Vector::Similarity->import('cosine_similarity'); 1 }
    or plan skip_all => 'Math::Vector::Similarity required for this test';
}

# Semantic test corpus: 2 programming texts, 1 cooking text
my @texts = (
  'Perl is a high-level programming language used for text processing and web development',
  'Python and JavaScript are popular languages for building software applications',
  'To make a perfect risotto you need arborio rice, broth, and parmesan cheese',
);
my $query = 'writing code and developing software';

sub test_engine {
  my ($name, $engine) = @_;

  subtest "$name embeddings" => sub {
    # Embed all texts
    my @vectors;
    for my $i (0 .. $#texts) {
      my $vec = eval { $engine->simple_embedding($texts[$i]) };
      if ($@) {
        fail "embedding text $i: $@";
        return;
      }
      ok(ref $vec eq 'ARRAY', "text $i returns arrayref");
      ok(scalar @$vec > 10, "text $i has dimensions (got " . scalar(@$vec) . ")");
      push @vectors, $vec;
    }

    # Embed query
    my $query_vec = eval { $engine->simple_embedding($query) };
    if ($@) {
      fail "embedding query: $@";
      return;
    }
    ok(ref $query_vec eq 'ARRAY', 'query returns arrayref');

    # All vectors should have same dimensions
    my $dim = scalar @{$vectors[0]};
    for my $i (1 .. $#vectors) {
      is(scalar @{$vectors[$i]}, $dim, "text $i has same dimensions as text 0");
    }
    is(scalar @$query_vec, $dim, 'query has same dimensions');

    # Semantic similarity: programming query should be closer to programming texts
    my $sim_prog1  = cosine_similarity($query_vec, $vectors[0]);
    my $sim_prog2  = cosine_similarity($query_vec, $vectors[1]);
    my $sim_cook   = cosine_similarity($query_vec, $vectors[2]);

    diag sprintf "  similarity to programming text 1: %.4f", $sim_prog1;
    diag sprintf "  similarity to programming text 2: %.4f", $sim_prog2;
    diag sprintf "  similarity to cooking text:       %.4f", $sim_cook;

    ok($sim_prog1 > $sim_cook, 'programming text 1 is more similar to query than cooking text');
    ok($sim_prog2 > $sim_cook, 'programming text 2 is more similar to query than cooking text');

    # Cross-similarity: programming texts should be more similar to each other than to cooking
    my $sim_prog_prog = cosine_similarity($vectors[0], $vectors[1]);
    my $sim_prog_cook = cosine_similarity($vectors[0], $vectors[2]);

    diag sprintf "  programming-programming similarity: %.4f", $sim_prog_prog;
    diag sprintf "  programming-cooking similarity:     %.4f", $sim_prog_cook;

    ok($sim_prog_prog > $sim_prog_cook, 'programming texts are more similar to each other than to cooking');
  };
}

# --- OpenAI ---

if ($ENV{TEST_LANGERTHA_OPENAI_API_KEY}) {
  require Langertha::Engine::OpenAI;
  my $openai = Langertha::Engine::OpenAI->new(
    api_key => $ENV{TEST_LANGERTHA_OPENAI_API_KEY},
  );
  test_engine('OpenAI', $openai);
}

# --- Mistral ---

if ($ENV{TEST_LANGERTHA_MISTRAL_API_KEY}) {
  require Langertha::Engine::Mistral;
  my $mistral = Langertha::Engine::Mistral->new(
    api_key => $ENV{TEST_LANGERTHA_MISTRAL_API_KEY},
    embedding_model => 'mistral-embed',
  );
  test_engine('Mistral', $mistral);
}

# --- Ollama (native) ---

if ($ENV{TEST_LANGERTHA_OLLAMA_URL}) {
  require Langertha::Engine::Ollama;
  my $ollama = Langertha::Engine::Ollama->new(
    url => $ENV{TEST_LANGERTHA_OLLAMA_URL},
    $ENV{TEST_LANGERTHA_OLLAMA_EMBEDDING_MODEL}
      ? (embedding_model => $ENV{TEST_LANGERTHA_OLLAMA_EMBEDDING_MODEL})
      : (),
  );
  test_engine('Ollama', $ollama);

  # --- OllamaOpenAI (same server, /v1 endpoint) ---
  require Langertha::Engine::OllamaOpenAI;
  my $ollama_oai = Langertha::Engine::OllamaOpenAI->new(
    url => $ENV{TEST_LANGERTHA_OLLAMA_URL} . '/v1',
    model => 'dummy',  # not used for embeddings
    $ENV{TEST_LANGERTHA_OLLAMA_EMBEDDING_MODEL}
      ? (embedding_model => $ENV{TEST_LANGERTHA_OLLAMA_EMBEDDING_MODEL})
      : (),
  );
  test_engine('OllamaOpenAI', $ollama_oai);
}

# --- LlamaCpp ---

if ($ENV{TEST_LANGERTHA_LLAMACPP_URL}) {
  require Langertha::Engine::LlamaCpp;
  my $llamacpp = Langertha::Engine::LlamaCpp->new(
    url => $ENV{TEST_LANGERTHA_LLAMACPP_URL},
  );
  test_engine('LlamaCpp', $llamacpp);
}

done_testing;
