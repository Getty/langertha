package Langertha::Ollama;
# ABSTRACT: Ollama API

use Moose;
use File::ShareDir::ProjectDistDir qw( :all );
use JSON::MaybeXS;

use Langertha::Ollama::Chat;

with 'Langertha::Role::'.$_ for (qw(
  JSON
  UserAgent
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

has keep_alive => (
  isa => 'Int',
  is => 'ro',
  predicate => 'has_keep_alive',
);

has json_format => (
  isa => 'Bool',
  is => 'ro',
  default => sub {0},
);

sub embedding_request {
  my ( $self, $prompt, %extra ) = @_;
  return $self->generate_request( generateEmbeddings =>
    model => $self->embedding_model,
    prompt => $prompt,
    %extra,
  );
}

sub chat {
  my ( $self, $query ) = @_;
  my $chain = $self->chat_chain( content => $query );
  return $self->user_agent->request_chain($chain);
}

sub chat_chain {
  my ( $self, %args ) = @_;
  return Langertha::Ollama::Chat->new(
    ollama => $self,
    %args,
  );
}

sub embedding {
  my ( $self ) = @_;
}

1;
