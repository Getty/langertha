package Langertha::Input;
our $VERSION = '0.404';
# ABSTRACT: Request input transformation helpers
use strict;
use warnings;
use Carp ();
use Langertha::Input::Tools;

Carp::carp(
  "Langertha::Input is a backwards-compatibility facade. New code should use "
  . "Langertha::Tool / Langertha::ToolChoice directly."
);

sub normalize_tools {
  shift;
  return Langertha::Input::Tools->normalize_tools(@_);
}

sub to_openai_tools {
  shift;
  return Langertha::Input::Tools->to_openai_tools(@_);
}

sub to_anthropic_tools {
  shift;
  return Langertha::Input::Tools->to_anthropic_tools(@_);
}

sub normalize_tool_choice {
  shift;
  return Langertha::Input::Tools->normalize_tool_choice(@_);
}

sub to_openai_tool_choice {
  shift;
  return Langertha::Input::Tools->to_openai_tool_choice(@_);
}

sub to_anthropic_tool_choice {
  shift;
  return Langertha::Input::Tools->to_anthropic_tool_choice(@_);
}

1;
