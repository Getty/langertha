package Langertha::OpenAI;
# ABSTRACT: OpenAI API

use Moose;
use File::ShareDir::ProjectDistDir qw( :all );
use WWW::Chain;

has api_key => (
  is => 'ro',
  predicate => 'has_api_key',
);

with 'Langertha::Role::'.$_ for (qw(
  JSON
  OpenAPI
  Chat
  Embedding
  Models
  SystemPrompt
  Tools
  ToolingAPI
));

sub update_request {
  my ( $self, $request ) = @_;
  $request->header('Authorization', 'Bearer '.$self->api_key) if $self->has_api_key;
}

sub default_model { 'gpt-3.5-turbo' }
sub default_embedding_model { 'text-embedding-3-small' }

sub openapi_file { yaml => dist_file('Langertha','openai.yaml') };

sub chat_request {
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
