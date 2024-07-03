package Langertha::Role::ToolingAPI;
# ABSTRACT: Role for APIs with tooling via API

use Moose::Role;

requires qw(
  parse_response
);

1;
