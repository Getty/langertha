package Langertha::Output;
our $VERSION = '0.309';
# ABSTRACT: Response output transformation helpers
use strict;
use warnings;
use Langertha::Output::Tools;

sub extract_from_raw {
  shift;
  return Langertha::Output::Tools->extract_from_raw(@_);
}

sub parse_hermes_calls_from_text {
  shift;
  return Langertha::Output::Tools->parse_hermes_calls_from_text(@_);
}

sub to_openai_tool_calls {
  shift;
  return Langertha::Output::Tools->to_openai_tool_calls(@_);
}

sub to_anthropic_tool_use_blocks {
  shift;
  return Langertha::Output::Tools->to_anthropic_tool_use_blocks(@_);
}

sub to_ollama_tool_calls {
  shift;
  return Langertha::Output::Tools->to_ollama_tool_calls(@_);
}

1;
