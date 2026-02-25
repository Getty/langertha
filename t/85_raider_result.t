#!/usr/bin/env perl
# ABSTRACT: Unit tests for Langertha::Raider::Result

use strict;
use warnings;

use Test2::Bundle::More;

use Langertha::Raider::Result;

# --- Stringification ---

my $final = Langertha::Raider::Result->new(
  type => 'final',
  text => 'Hello world',
);
is("$final", 'Hello world', 'final result stringifies to text');
ok($final->is_final, 'is_final returns true for final type');
ok(!$final->is_question, 'is_question returns false');
ok(!$final->is_pause, 'is_pause returns false');
ok(!$final->is_abort, 'is_abort returns false');

# --- Stringification without text ---

my $question = Langertha::Raider::Result->new(
  type    => 'question',
  content => 'What color?',
  options => ['red', 'blue', 'green'],
);
is("$question", '', 'question result stringifies to empty string (no text)');
ok(!$question->is_final, 'is_final returns false for question');
ok($question->is_question, 'is_question returns true');
is($question->content, 'What color?', 'content holds the question');
is_deeply($question->options, ['red', 'blue', 'green'], 'options preserved');

# --- Pause result ---

my $pause = Langertha::Raider::Result->new(
  type    => 'pause',
  content => 'Waiting for user input',
);
ok($pause->is_pause, 'is_pause returns true');
is($pause->content, 'Waiting for user input', 'pause content preserved');

# --- Abort result ---

my $abort = Langertha::Raider::Result->new(
  type    => 'abort',
  content => 'Cannot complete task',
);
ok($abort->is_abort, 'is_abort returns true');
is($abort->content, 'Cannot complete task', 'abort content preserved');

# --- Predicates ---

ok($final->has_text, 'has_text for final');
ok(!$final->has_content, 'no has_content for final without content');
ok(!$question->has_text, 'no has_text for question');
ok($question->has_content, 'has_content for question');
ok($question->has_options, 'has_options for question with options');

my $pause_no_opts = Langertha::Raider::Result->new(
  type    => 'pause',
  content => 'reason',
);
ok(!$pause_no_opts->has_options, 'no has_options when not set');

# --- Backward compatibility: comparison operators via overload fallback ---

my $result = Langertha::Raider::Result->new(type => 'final', text => 'test123');
like("$result", qr/test123/, 'final result matches regex via stringification');
is(length("$result"), 7, 'length works via stringification');

done_testing;
