package Langertha::OpenAI;
# ABSTRACT: OpenAI API

use Moose;
use File::ShareDir::ProjectDistDir qw( :all );
use WWW::Chain;
use Carp qw( croak );

with 'Langertha::Role::'.$_ for (qw(
  JSON
  UserAgent
  OpenAPI
  Models
  SystemPrompt
  Tools
  ToolingAPI
  Chat
  Embedding
));

has api_key => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_OPENAI_API_KEY} || $ENV{OPENAI_API_KEY} || croak "".(ref $self)." requires OPENAI_API_KEY";
}

sub update_request {
  my ( $self, $request ) = @_;
  $request->header('Authorization', 'Bearer '.$self->api_key);
}

sub default_model { 'gpt-3.5-turbo' }
sub default_embedding_model { 'text-embedding-3-small' }

sub openapi_file { yaml => dist_file('Langertha','openai.yaml') };

sub chat_request {
  my ( $self, $prompt, %extra ) = @_;
  return $self->generate_request( createChatCompletion =>
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

sub embedding_request {
  my ( $self, $input, %extra ) = @_;
  return $self->generate_request( createEmbedding =>
    model => $self->embedding_model,
    input => $input,
    %extra,
  );
}

1;
