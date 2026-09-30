#!/usr/bin/env perl
# ABSTRACT: Usage reads the provider-reported cost (xAI cost_in_usd_ticks / cost_in_nano_usd) as cost_usd

use strict;
use warnings;

use Test2::Bundle::More;
use HTTP::Response;
use Path::Tiny qw( path );

use Langertha::Usage;
use Langertha::Engine::XAI;

# karr k354, ADR 0031 / ADR 0018 tier 1. xAI reports what a request was
# actually billed (after cache discounts, including server-side tool fees) in
# the usage block: cost_in_usd_ticks on chat/completions, Responses, images
# and video (1 USD = 10^10 ticks), and on Responses also cost_in_nano_usd
# (1 USD = 10^9 nano-USD), both nullable there. Langertha only kept the numbers
# in the raw usage hash, so a caller had to know the provider's unit to read
# the one figure that needs no price table. Usage->cost_usd is that figure in
# USD, read at the universal door so Response, stream chunks and from_raw all
# get it; unknown stays undef, never 0 (a 0 would read as "free").
#
# The fixtures are NOT live captures (no xAI key; live calls need the
# maintainer's approval). They are shaped from the xAI REST reference
# (docs.x.ai/developers/rest-api-reference/inference/chat-completions.md,
# .../responses.md, .../images.md) and the cost-tracking guide
# (docs.x.ai/developers/cost-tracking, last updated 2026-09-03), whose
# example 37756000 ticks is $0.0038.

my $data_dir = path(__FILE__)->parent->child('data');

sub http_json {
  my ($name) = @_;
  my $res = HTTP::Response->new( 200, 'OK' );
  $res->header( 'Content-Type' => 'application/json' );
  $res->content( $data_dir->child($name)->slurp_raw );
  return $res;
}

sub near { abs( $_[0] - $_[1] ) < 1e-12 }

subtest 'XAI chat/completions: cost_in_usd_ticks reaches Response->usage->cost_usd' => sub {
  my $xai  = Langertha::Engine::XAI->new( api_key => 'k' );
  my $resp = $xai->chat_response( http_json('xai_chat_cost_doc.json') );
  my $usage = $resp->usage;
  ok defined $usage->cost_usd, 'cost_usd is reported';
  ok near( $usage->cost_usd, 0.0037756 ), '37756000 ticks / 1e10 = $0.0037756'
    or diag $usage->cost_usd;
  is $usage->{cost_in_usd_ticks}, 37756000, 'the integer ticks stay verbatim in the usage hash';
  is $usage->input_tokens, 199, 'token counts unchanged';
  is $usage->cached_tokens, 128, 'cache count unchanged';
};

subtest 'XAI stream: the include_usage frame carries the cost' => sub {
  my $xai = Langertha::Engine::XAI->new( api_key => 'k' );
  my $buf = $data_dir->child('xai_stream_cost_doc.sse')->slurp_raw;
  my $chunks = $xai->_process_stream_buffer( \$buf, 'sse', 1, {} );
  my $usage  = Langertha::Usage->from_hash( $xai->aggregate_usage($chunks) );
  ok near( $usage->cost_usd, 0.0037756 ), 'streamed cost_usd from the usage-only frame';
};

subtest 'xAI Responses usage block: both spellings, ticks first' => sub {
  my $nano = Langertha::Usage->from_hash( {
    input_tokens => 10, output_tokens => 2, cost_in_nano_usd => 3775600 } );
  ok near( $nano->cost_usd, 0.0037756 ), 'cost_in_nano_usd alone: nano / 1e9';

  my $both = Langertha::Usage->from_hash( {
    input_tokens => 10, output_tokens => 2,
    cost_in_usd_ticks => 37756123, cost_in_nano_usd => 3775612 } );
  ok near( $both->cost_usd, 0.0037756123 ), 'both present: the finer ticks win';

  my $null_ticks = Langertha::Usage->from_hash( {
    input_tokens => 10, output_tokens => 2,
    cost_in_usd_ticks => undef, cost_in_nano_usd => 3775600 } );
  ok near( $null_ticks->cost_usd, 0.0037756 ), 'null ticks fall back to nano';

  my $null_both = Langertha::Usage->from_hash( {
    input_tokens => 10, output_tokens => 2,
    cost_in_usd_ticks => undef, cost_in_nano_usd => undef } );
  is $null_both->cost_usd, undef, 'both null: not reported';

  my $zero = Langertha::Usage->from_hash( { input_tokens => 1, cost_in_usd_ticks => 0 } );
  ok defined $zero->cost_usd && $zero->cost_usd == 0, 'a reported 0 stays a defined 0';
};

subtest 'xAI image body via from_raw' => sub {
  my $usage = Langertha::Usage->from_raw( {
    data  => [ { url => 'https://imgen.x.ai/x.jpeg' } ],
    usage => { cost_in_usd_ticks => 400000000 } } );
  ok near( $usage->cost_usd, 0.04 ), '400000000 ticks = $0.04';
};

subtest 'no provider cost: undef, not 0' => sub {
  is( Langertha::Usage->from_hash( { prompt_tokens => 5, completion_tokens => 1 } )->cost_usd,
    undef, 'OpenAI usage block has no cost' );
  is( Langertha::Usage->new( input_tokens => 5 )->cost_usd, undef, 'new without cost_usd' );
  ok near( Langertha::Usage->new( cost_usd => 0.5 )->cost_usd, 0.5 ), 'new takes cost_usd';
};

subtest 'merge: summed only when both sides report a cost' => sub {
  my $one = Langertha::Usage->from_hash( { input_tokens => 1, cost_in_usd_ticks => 10_000_000 } );
  my $two = Langertha::Usage->from_hash( { input_tokens => 2, cost_in_usd_ticks => 30_000_000 } );
  ok near( $one->merge($two)->cost_usd, 0.004 ), 'both reported: summed';
  my $none = Langertha::Usage->from_hash( { input_tokens => 3 } );
  is $one->merge($none)->cost_usd, undef, 'one side unknown: the sum is unknown';
  is $none->merge($one)->cost_usd, undef, 'either order';
};

done_testing;
