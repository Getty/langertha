package Langertha::OpenAI;
# ABSTRACT: OpenAI API

use Moose;
use File::ShareDir::ProjectDistDir qw( :all );

has api_key => (
  is => 'ro',
  predicate => 'has_api_key',
);

sub update_request {
  my ( $self, $request ) = @_;
  $request->header('Authorization', 'Bearer '.$self->api_key) if $self->has_api_key;
}

with qw(
  Langertha::Role::OpenAPI
  Langertha::Role::Chat
  Langertha::Role::Models
  Langertha::Role::SystemPrompt
  Langertha::Role::Tools
);

sub default_model { 'gpt-3.5-turbo' }

sub openapi_file { yaml => dist_file('Langertha','openai.yaml') };

sub chat {
  my ( $self, $prompt, %extra ) = @_;
  return $self->generate_request( generateChat =>
    model => $self->model,
    messages => [$self->has_system_prompt ? ({
      role => "system",
      content => $self->system_prompt,
    }) : (),{
      role => "user",
      content => $prompt,
    }],
    $self->has_tools ? (
      tools => [map { $_->tool_definition } @{$self->tools}]
    ) : (),
  );
}

1;
