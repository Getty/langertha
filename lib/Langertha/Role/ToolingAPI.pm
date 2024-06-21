package Langertha::Role::ToolingAPI;
# ABSTRACT: Role for APIs with tooling via prompt

use Moose::Role;

requires qw(
  parse_response
);

1;
