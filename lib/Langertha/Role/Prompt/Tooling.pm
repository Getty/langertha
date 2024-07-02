package Langertha::Role::Prompt::Tooling;
# ABSTRACT: Prompt tooling role

use Moose::Role;

has tools_source => (
  is => 'ro',
  required => 1,
  does => 'Langertha::Role::Tools',
);

requires qw(
  tooling_prompt
  tooling_parser
);

1;