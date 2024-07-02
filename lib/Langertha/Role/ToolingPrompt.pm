package Langertha::Role::ToolingPrompt;
# ABSTRACT: Role for APIs with tooling via prompt

use Moose::Role;
use Module::Runtime qw( use_module );

requires qw(
  parse_response
  system_prompt
);

has prompt_tooling_class => (
  is => 'ro',
  isa => 'Str',
  lazy_build => 1,
);
sub _build_prompt_tooling_class {
  my ( $self ) = @_;
  return 'Langertha::Prompt::Tooling::Optional';
}

has prompt_tooling => (
  is => 'ro',
  does => 'Langertha::Role::Prompt::Tooling',
  lazy_build => 1,
);
sub _build_prompt_tooling {
  my ( $self ) = @_;
  return use_module($self->prompt_tooling_class)->new(
    tools_source => $self,
  );
}

has tools_prompt => (
  is => 'ro',
  isa => 'Str',
  lazy_build => 1,
);
sub _build_tools_prompt {
  my ( $self ) = @_;
  return $self->prompt_tooling->tooling_prompt;
}

around system_prompt => sub {
  my $orig = shift;
  my $self = shift;
  return $self->$orig(@_) if scalar @_ > 0;
  if ($self->has_tools) {
    # return $self->tools_prompt."\n\n\n".$self->$orig;
    return $self->$orig."\n\n\n".$self->tools_prompt;
  } else {
    return $self->$orig;
  }
};

1;
