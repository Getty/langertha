package Langertha::Engine::Ollama;
# ABSTRACT: Ollama API

use Moose;
use File::ShareDir::ProjectDistDir qw( :all );
use Carp qw( croak );
use JSON::MaybeXS;

use Langertha::Engine::OpenAI;

with 'Langertha::Role::'.$_ for (qw(
  JSON
  HTTP
  OpenAPI
  Models
  Seed
  SystemPrompt
  Chat
  Embedding
));

sub openai {
  my ( $self, %args ) = @_;
  my $url = $self->url || $self->openapi->openapi_document->get('/servers/0/url');
  return Langertha::Engine::OpenAI->new(
    url => $self->url.'/v1',
    model => $self->model,
    $self->embedding_model ? ( embedding_model => $self->embedding_model ) : (),
    $self->chat_model ? ( chat_model => $self->chat_model ) : (),
    $self->has_system_prompt ? ( system_prompt => $self->system_prompt ) : (),
    api_key => 'ollama',
    compatibility_for_engine => $self,
    supported_operations => [qw(
      createChatCompletion
    )],
    %args,
  );
}

sub new_openai {
  my ( $class, %args ) = @_;
  my $tools = delete $args{tools} || [];
  my $self = $class->new(%args);
  return $self->openai( tools => $tools );
}

sub default_model { 'llama3.1' }
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
  return $self->generate_request( generateEmbeddings => sub { $self->embedding_response(shift) },
    model => $self->embedding_model,
    prompt => $prompt,
    %extra,
  );
}

sub embedding_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  # tracing
  return $data->{embedding};
}

sub chat_request {
  my ( $self, $messages, %extra ) = @_;
  return $self->generate_request( generateChat => sub { $self->chat_response(shift) },
    model => $self->chat_model,
    messages => $messages,
    stream => JSON->false,
    $self->json_format ? ( format => 'json' ) : (),
    $self->has_keep_alive ? ( keep_alive => $self->keep_alive ) : (),
    options => {
      $self->has_seed ? ( seed => $self->seed )
        : $self->randomize_seed ? ( seed => $self->random_seed ) : (),
    },
    %extra,
  );
}

sub chat_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  # tracing
  my @messages = $data->{message};
  return $messages[0]->{content};
}

sub tags { $_[0]->tags_request }
sub tags_request {
  my ( $self ) = @_;
  return $self->generate_request( getModels => sub { $self->tags_response(shift) } );
}

sub tags_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  my @model_list = map { $_->{model} } @{$data->{models}};
  $self->models(\@model_list);
  return $data->{models};
}

sub simple_tags {
  my ( $self ) = @_;
  my $request = $self->tags;
  my $response = $self->user_agent->request($request);
  return $request->response_call->($response);
}

__PACKAGE__->meta->make_immutable;

=head1 SYNOPSIS

  use Langertha::Engine::Ollama;

  my $ollama = Langertha::Engine::Ollama->new(
    url => $ENV{OLLAMA_URL},
    model => 'llama3.1',
    system_prompt => 'You are a helpful assistant',
  );

  print($ollama->simple_chat('Say something nice'));

  my $embedding = $ollama->embedding($content);

  # Get OpenAI compatible API access to Ollama 
  my $ollama_openai = $ollama->openai;

=head1 DESCRIPTION

B<THIS API IS WORK IN PROGRESS>

=head1 HOW TO INSTALL OLLAMA

L<https://github.com/ollama/ollama/tree/main>

=cut
