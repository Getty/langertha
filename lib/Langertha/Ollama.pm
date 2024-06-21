package Langertha::Ollama;
# ABSTRACT: Ollama API

use Moose;
use File::ShareDir::ProjectDistDir qw( :all );
use WWW::Chain;
use JSON::MaybeXS;

with 'Langertha::Role::'.$_ for (qw(
  JSON
  OpenAPI
  Chat
  Embedding
  Models
  SystemPrompt
  Tools
  ToolingPrompt
));

sub default_model { 'llama3' }
sub default_embedding_model { 'mxbai-embed-large' }

sub openapi_file { yaml => dist_file('Langertha','ollama.yaml') };

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
    stream => JSON->false,
    %extra,
  );
}

sub embedding_request {
  my ( $self, $prompt, %extra ) = @_;
  return $self->generate_request( generateEmbeddings =>
    model => $self->embedding_model,
    prompt => $prompt,
    %extra,
  );
}

1;
