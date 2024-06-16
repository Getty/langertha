package Langertha::Ollama;
# ABSTRACT: Ollama API

use Moose;
use File::ShareDir::ProjectDistDir qw( :all );

with qw(
  Langertha::Role::JSON
  Langertha::Role::OpenAPI
  Langertha::Role::Chat
  Langertha::Role::Models
  Langertha::Role::SystemPrompt
  Langertha::Role::Tools
);

sub default_model { 'llama3' }

sub openapi_file { yaml => dist_file('Langertha','ollama.yaml') };

sub chat {
  my ( $self, $prompt, %extra ) = @_;
  return unless $prompt;
  return $self->generate_request( generateChat =>
    model => $self->model,
    messages => [$self->has_system_prompt ? ({
      role => "system",
      content => $self->system_prompt,
    }) : (),{
      role => "user",
      content => $prompt,
    }],
    stream => JSON->false,
    %extra,
  );
}

1;
