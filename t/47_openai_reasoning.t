#!/usr/bin/env perl
# ABSTRACT: OpenAI model-gated reasoning_effort clamp, Chat vs Responses symmetry (karr k140)

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;

use Langertha::Reasoning;
use Langertha::Engine::OpenAI;
use Langertha::Engine::OpenAIResponses;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

# What each OpenAI wire emits for (model, effort), read straight off the value
# object: undef means the effort was clamped away, otherwise the passed value.
sub emit_openai {
  my ( $model, $effort ) = @_;
  my %kw = Langertha::Reasoning->new( effort => $effort, model => $model )->to('openai');
  return exists $kw{reasoning_effort} ? $kw{reasoning_effort} : undef;
}
sub emit_responses {
  my ( $model, $effort ) = @_;
  my %kw = Langertha::Reasoning->new( effort => $effort, model => $model )->to('responses');
  return exists $kw{reasoning} ? $kw{reasoning}{effort} : undef;
}

my @EFFORTS = qw( none minimal low medium high xhigh max );

# Advisor-verified per-model ladders (karr k140, 2026-09-01). 1 = accepted, 0 =
# clamped away. The two generations do NOT overlap: gpt-5.6/gpt-5.5 have
# none/xhigh(/max) but no minimal; legacy gpt-5 has minimal but no none/xhigh/max.
# Unlisted ids (gpt-5.1, gpt-4o-mini) keep the whole normalized enum.
my %EXPECT = (
  'gpt-5.6-terra' => { none => 1, minimal => 0, low => 1, medium => 1, high => 1, xhigh => 1, max => 1 },
  'gpt-5.6'       => { none => 1, minimal => 0, low => 1, medium => 1, high => 1, xhigh => 1, max => 1 },
  'gpt-5.6-luna'  => { none => 1, minimal => 0, low => 1, medium => 1, high => 1, xhigh => 1, max => 1 },
  'gpt-5.5'       => { none => 1, minimal => 0, low => 1, medium => 1, high => 1, xhigh => 1, max => 0 },
  'gpt-5.5-pro'   => { none => 1, minimal => 0, low => 1, medium => 1, high => 1, xhigh => 1, max => 0 },
  'gpt-5'         => { none => 0, minimal => 1, low => 1, medium => 1, high => 1, xhigh => 0, max => 0 },
  'gpt-5-mini'    => { none => 0, minimal => 1, low => 1, medium => 1, high => 1, xhigh => 0, max => 0 },
  'gpt-5.1'       => { none => 1, minimal => 1, low => 1, medium => 1, high => 1, xhigh => 1, max => 1 },
  'gpt-4o-mini'   => { none => 1, minimal => 1, low => 1, medium => 1, high => 1, xhigh => 1, max => 1 },
);

for my $model ( sort keys %EXPECT ) {
  for my $effort ( @EFFORTS ) {
    my $want = $EXPECT{$model}{$effort} ? $effort : undef;
    my $chat = emit_openai( $model, $effort );
    my $resp = emit_responses( $model, $effort );

    is( $chat, $want, "openai:    $model + $effort -> " . ( $want // 'DROP' ) );
    # Both OpenAI surfaces $ref the same ReasoningEffort schema: the model-gated
    # clamp is shared, so Chat Completions and Responses can never diverge.
    is( $resp, $chat, "symmetry:  $model + $effort agrees on both wires" );
  }
}

# --- Engine-level: the two headline drifts from the ticket -----------------

# Drift 1a: the wrong blanket `max` drop is gone. The default engine model is
# gpt-5.6-terra, which DOES accept max -> it must reach the wire now.
{
  my $engine = Langertha::Engine::OpenAI->new( api_key => 'k', reasoning_effort => 'max' );
  my $body = $json->decode( $engine->chat('hi')->content );
  is( $body->{model}, 'gpt-5.6-terra', 'OpenAI default model is gpt-5.6-terra' );
  is( $body->{reasoning_effort}, 'max',
    'gpt-5.6-terra keeps reasoning_effort=max (blanket max-drop removed)' );
}

# Drift 1b: `minimal` is the legacy spelling; gpt-5.6-terra rejects it, so it
# must be clamped away rather than passed straight through.
{
  my $engine = Langertha::Engine::OpenAI->new( api_key => 'k', reasoning_effort => 'minimal' );
  my $body = $json->decode( $engine->chat('hi')->content );
  ok( !exists $body->{reasoning_effort},
    'gpt-5.6-terra drops minimal (not on the gpt-5.6 ladder)' );
}

# The Responses engine (gpt-5.5-pro) now clamps identically to Chat Completions:
# it drops max and minimal, keeps high. Before k140 to_responses clamped nothing.
sub resp_body {
  my ( %args ) = @_;
  my $engine = Langertha::Engine::OpenAIResponses->new( api_key => 'k', %args );
  return $json->decode( $engine->chat_request([ { role => 'user', content => 'hi' } ])->content );
}
{
  my $body = resp_body( model => 'gpt-5.5-pro', reasoning_effort => 'max' );
  ok( !exists $body->{reasoning}, 'gpt-5.5-pro (Responses) drops max (not on gpt-5.5 ladder)' );
}
{
  my $body = resp_body( model => 'gpt-5.5-pro', reasoning_effort => 'high' );
  is_deeply( $body->{reasoning}, { effort => 'high' }, 'gpt-5.5-pro (Responses) keeps high' );
}
{
  my $body = resp_body( model => 'gpt-5.5-pro', reasoning_effort => 'minimal' );
  ok( !exists $body->{reasoning}, 'gpt-5.5-pro (Responses) drops minimal' );
}

done_testing;
