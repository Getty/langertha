#!/usr/bin/env perl
# ABSTRACT: Live integration test for AKI.IO native API

use strict;
use warnings;

use Test2::Bundle::More;

BEGIN {
  unless ($ENV{TEST_LANGERTHA_AKI_API_KEY}) {
    plan skip_all => 'Set TEST_LANGERTHA_AKI_API_KEY to run this test';
  }
}

use Langertha::Engine::AKI;

# --- list_models ---

my $aki = Langertha::Engine::AKI->new(
  api_key => $ENV{TEST_LANGERTHA_AKI_API_KEY},
);

my $endpoints = $aki->list_models;
ok(ref $endpoints eq 'ARRAY', 'list_models returns arrayref');
ok(scalar @$endpoints > 0, 'list_models returns at least one endpoint');
diag "Available AKI endpoints: " . join(', ', @$endpoints);

# --- list_models caching ---

my $endpoints2 = $aki->list_models;
is_deeply($endpoints2, $endpoints, 'list_models returns cached result');

my $endpoints3 = $aki->list_models(force_refresh => 1);
ok(ref $endpoints3 eq 'ARRAY', 'list_models force_refresh returns arrayref');

# --- endpoint_details ---

my $details = $aki->endpoint_details($endpoints->[0]);
ok(ref $details eq 'HASH', 'endpoint_details returns hashref');
ok($details->{name}, 'endpoint_details has name');
ok($details->{title} || $details->{description}, 'endpoint_details has title or description');
diag "First endpoint details: name=$details->{name} title=" . ($details->{title} // 'n/a');

# --- simple_chat ---

# Pick a chat endpoint (prefer llama3_8b_chat specifically, then any *_chat)
my $chat_model = $ENV{TEST_LANGERTHA_AKI_MODEL};
unless ($chat_model) {
  my @chat_endpoints = grep { /_chat$/ } @$endpoints;
  # Prefer llama3_8b_chat as it's known to work with our v2 API format
  ($chat_model) = grep { $_ eq 'llama3_8b_chat' } @chat_endpoints;
  $chat_model ||= $chat_endpoints[0] || $endpoints->[0];
}
diag "Using chat model: $chat_model";

my $chat_aki = Langertha::Engine::AKI->new(
  api_key => $ENV{TEST_LANGERTHA_AKI_API_KEY},
  model => $chat_model,
);

my $response = $chat_aki->simple_chat('Say exactly: Hello Langertha');
ok(defined $response, 'simple_chat returns a response');
ok(length $response > 0, 'simple_chat response is non-empty');
diag "AKI chat response: $response";

# --- openai() method ---

my $aki_openai = $chat_aki->openai;
isa_ok($aki_openai, 'Langertha::Engine::AKIOpenAI');
is($aki_openai->model, $chat_model, 'openai() preserves model');

done_testing;
