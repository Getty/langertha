package Langertha::Role::ToolingPrompt;
# ABSTRACT: Role for APIs with tooling via prompt

use Moose::Role;

requires qw(
  parse_response
  system_prompt
);

has tools_prompt => (
  is => 'ro',
  isa => 'Str',
  lazy_build => 1,
);
sub _build_tools_prompt {
  my ( $self ) = @_;
  my $tools = $self->tools_definition;
  return <<"__EOP__";

You are given a set of possible functions inside <function-definitions> tags.
Calling these functions are optional. Carefully consider the question and
determine if one or more functions can be used to answer the question. Place
your thoughts and reasoning behind your decision in <function-thoughts> tags.
If the given question lacks the parameters required by the function, point it
out in <function-thoughts> tags. Below is a list of function definitions:

<function-definitions>
  $tools
</function-definitions>

If you wish to call a particular function, specify the name of the function and
any arguments in a way that conforms to that function's schema inside
<function-call> tags. Function calls should be in this format:

<function-thoughts>
  Calling func1 would be helpful because of ...
</function-thoughts>

<function-call>[
  function_name(params_name=params_value, params_name2=params_value2...),
  other_function_name(params)
]</function-call>, WITHOUT any answer.

If you do not wish to call any functions, say so in the <function-thoughts>
tags followed by <function-call>None</function-call><answer>...</answer>

If and only if NO function calls are made, answer the question to the best of
your ability inside <answer> tags.  If you are unsure of the answer, say so in
<answer> tags.

__EOP__
}

around system_prompt => sub {
  my $orig = shift;
  my $self = shift;
  return $self->$orig(@_) if scalar @_ > 0;
  if ($self->has_tools) {
    return $self->tools_prompt."\n\n\n".$self->$orig;
  } else {
    return $self->$orig;
  }
};

1;
