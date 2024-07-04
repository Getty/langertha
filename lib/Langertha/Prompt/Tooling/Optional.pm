package Langertha::Prompt::Tooling::Optional;

use Moose;

with qw(
  Langertha::Role::Prompt::Tooling
  Langertha::Role::JSON
);

sub tooling_prompt {
  my ( $self ) = @_;
  my $tools = $self->tools_source->tools_definition_json;
  return <<"__EOP__";

You have access to the following tools specified by this JSON:

$tools

The way you use the tools is by specifying a JSON hash. Specifically, this JSON
should have an `name` key, with the name of the tool to be used, and a
`parameters` key, with the parametes of the tool to be used. The `parameters`
should be given as JSON string inside the JSON hash. This JSON hash must be
put in a JSON array, to allow you to call several tools at once. Here is an
example of the JSON that you need to use:

[{
  "name": "first_function_to_call",
  "parameters": "{\\"parameter_name\\":\\"Value for parameter\\"}"
},{
  "name": "second_function_to_call",
  "parameters": "{\\"another_parameter_name\\":\\"Value for parameter\\"}"
}]

Calling these functions is optional. Carefully consider the question and
determine if one or more functions can be used to answer the question, or to
provide more context to better answer the question. If you are calling a
function, do not reply with any other information then the JSON hash.

__EOP__
}

sub tooling_parser {
  my ( $self, $response ) = @_;
  
}

1;