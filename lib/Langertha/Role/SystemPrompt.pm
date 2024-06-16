package Langertha::Role::SystemPrompt;
# ABSTRACT: Role for APIs with system prompt

use Moose::Role;

has system_prompt => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_system_prompt',
);

1;
