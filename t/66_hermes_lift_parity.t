#!/usr/bin/env perl
# ABSTRACT: One hermes lift — ToolCall->extract_hermes_from_text and the engine split agree

use strict;
use warnings;

use Test2::Bundle::More;

use Langertha::ToolCall;
use Langertha::Output::Tools;
use Langertha::Engine::NousResearch;

# karr k255 (ADR 0001, k253 Update): the public door
# Langertha::ToolCall->extract_hermes_from_text (Output::Tools, skeid's
# protocols) and the engine's _hermes_split_text (chat_f, streaming, the tool
# loop) used to disagree on a <tool_call> block that carries no call: the door
# deleted it, the engine kept it as text. Text the model wrote must not vanish
# on one path and survive on another, so both doors give the same answer, and
# a block without a call stays where it was.

my @cases = (
  [ 'invalid JSON kept as text',
    'Hi <tool_call>{not json}</tool_call> there.',
    'Hi <tool_call>{not json}</tool_call> there.', [] ],
  [ 'object without name kept as text',
    'A <tool_call>{"arguments":{"x":1}}</tool_call> B',
    'A <tool_call>{"arguments":{"x":1}}</tool_call> B', [] ],
  [ 'empty name kept as text',
    '<tool_call>{"name":"","arguments":{}}</tool_call>',
    '<tool_call>{"name":"","arguments":{}}</tool_call>', [] ],
  [ 'non-object JSON kept as text',
    'x <tool_call>[1,2]</tool_call> y',
    'x <tool_call>[1,2]</tool_call> y', [] ],
  [ 'nested tag block kept as text',
    'N <tool_call><tool_call>{"name":"go","arguments":{}}</tool_call></tool_call> end',
    'N <tool_call><tool_call>{"name":"go","arguments":{}}</tool_call></tool_call> end', [] ],
  [ 'valid call lifted, broken one beside it kept in place',
    'a <tool_call>oops</tool_call> b <tool_call>{"name":"go","arguments":{"x":1}}</tool_call> c',
    'a <tool_call>oops</tool_call> b  c', [ { name => 'go', arguments => { x => 1 } } ] ],
  [ 'non-object arguments become {}',
    '<tool_call>{"name":"go","arguments":"x=1"}</tool_call>',
    '', [ { name => 'go', arguments => {} } ] ],
);

my $engine = Langertha::Engine::NousResearch->new( api_key => 'test-key' );

for my $case (@cases) {
  my ( $label, $text, $want_text, $want_calls ) = @$case;

  my ( $door_text, $door_calls ) = Langertha::ToolCall->extract_hermes_from_text($text);
  is( $door_text, $want_text, "ToolCall door: $label (text)" );
  is_deeply( [ map { { name => $_->name, arguments => $_->arguments } } @$door_calls ],
    $want_calls, "ToolCall door: $label (calls)" );

  my ( $eng_text, $eng_calls ) = $engine->_hermes_split_text($text);
  is( $eng_text, $door_text, "engine split agrees: $label (text)" );
  is_deeply( $eng_calls, $want_calls, "engine split agrees: $label (calls)" );

  my ( $out_text, $out_calls ) = Langertha::Output::Tools->parse_hermes_calls_from_text($text);
  is( $out_text, $door_text, "Output::Tools agrees: $label (text)" );
  is( scalar @$out_calls, scalar @$want_calls, "Output::Tools agrees: $label (count)" );
}

# A custom call tag reaches the door, and the default tag is then plain text.
{
  my $text = '<function_call>{"name":"go","arguments":{}}</function_call> <tool_call>{"name":"no"}</tool_call>';
  my ( $clean, $calls ) = Langertha::ToolCall->extract_hermes_from_text( $text, tag => 'function_call' );
  is( scalar @$calls, 1, 'tag option lifts the custom tag' );
  is( $calls->[0]->name, 'go', 'tag option: call name' );
  is( $clean, '<tool_call>{"name":"no"}</tool_call>', 'tag option: the default tag is text' );

  my $custom = Langertha::Engine::NousResearch->new( api_key => 'k', hermes_call_tag => 'function_call' );
  my ( $eng_clean, $eng_calls ) = $custom->_hermes_split_text($text);
  is( $eng_clean, $clean, 'engine with hermes_call_tag agrees with the door (text)' );
  is( scalar @$eng_calls, 1, 'engine with hermes_call_tag agrees with the door (calls)' );
}

done_testing;
