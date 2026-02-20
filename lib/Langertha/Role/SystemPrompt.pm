package Langertha::Role::SystemPrompt;
# ABSTRACT: Role for APIs with system prompt
our $VERSION = '0.101';
use Moose::Role;

has system_prompt => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_system_prompt',
);

1;
