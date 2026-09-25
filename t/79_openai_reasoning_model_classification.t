#!/usr/bin/env perl
# ABSTRACT: k186 table pinning which OpenAI model ids count as reasoning models
#           for the temperature gate (drop temperature vs keep temperature).

# The temperature gate (ADR 0025) first asks "is this an OpenAI reasoning model?"
# before it resolves the effort. Getting that classification wrong in the
# reasoning direction silently drops a caller's temperature on a model that
# would have honored it -- the worse error -- so every id below is pinned.
#
# Observation point: with an explicit, non-'none' reasoning effort the predicate
# Engine::OpenAI::_temperature_rejected_by_reasoning answers 1 exactly when the
# model is classified as a reasoning model (the effort resolution after the
# classification always rejects temperature at 'high'). This is independent of
# WHERE the classification lives, so the table holds across the k186 move of the
# classification from an engine regex into Langertha::Reasoning::Profile.
#
# Reasoning: o-series, gpt-5 (non-chat), gpt-5.N (non-chat), gpt-6*.
# Non-reasoning: gpt-4o / gpt-4.1, every gpt-5-chat and gpt-5.N-chat id, and any
# unknown id (the unlisted default must never classify as reasoning).

use strict;
use warnings;

use Test2::Bundle::More;

use Langertha::Engine::OpenAI;
use Langertha::Engine::OpenAIResponses;

my @REASONING = qw(
  o1 o3 o3-mini o4-mini
  gpt-5 gpt-5-mini gpt-5-nano gpt-5-codex gpt-5-pro
  gpt-5.1 gpt-5.1-codex-max gpt-5.2 gpt-5.3 gpt-5.4
  gpt-5.5 gpt-5.5-pro gpt-5.6 gpt-5.6-luna gpt-5.6-terra gpt-5.7
  gpt-6 gpt-6-astra
);

my @NON_REASONING = qw(
  gpt-4o gpt-4o-mini gpt-4o-mini-2024-07-18 gpt-4.1 gpt-4.1-mini
  gpt-5-chat gpt-5-chat-latest
  gpt-image-1 gpt-test gpt-x gpt-oss-120b
  claude-opus-4-8 gemini-2.5-flash some-unknown-model
);

# The dotted-chat ids: the pre-k186 regex (?!-chat) lookahead only saw a literal
# "-chat" directly after "gpt-5", so these were misclassified as reasoning.
my @DOTTED_CHAT = qw(
  gpt-5.1-chat-latest gpt-5.2-chat-latest gpt-5.3-chat-latest
  gpt-5.5-chat-latest gpt-5.6-chat gpt-5.6-chat-latest
);

sub classified_reasoning {
  my ( $class, $model ) = @_;
  my $engine = $class->new( api_key => 'k', model => $model );
  return $engine->_temperature_rejected_by_reasoning( { reasoning_effort => 'high' } );
}

for my $class (qw( Langertha::Engine::OpenAI Langertha::Engine::OpenAIResponses )) {
  for my $model (@REASONING) {
    is( classified_reasoning( $class, $model ), 1,
      "$class $model: reasoning model (temperature dropped at effort=high)" );
  }
  for my $model (@NON_REASONING) {
    is( classified_reasoning( $class, $model ), 0,
      "$class $model: non-reasoning (temperature kept)" );
  }
  todo 'k186: dotted-chat lookahead gap in the engine regex' => sub {
    for my $model (@DOTTED_CHAT) {
      is( classified_reasoning( $class, $model ), 0,
        "$class $model: dotted chat id is non-reasoning (temperature kept)" );
    }
  };
}

done_testing;
