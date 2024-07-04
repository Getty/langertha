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

sub embedding {
  my ( $self ) = @_;
}

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

sub chat_request {
  my ( $self, $messages, %extra ) = @_;
  return $self->generate_request( generateChat =>
    model => $self->chat_model,
    messages => $messages->to_api,
    stream => JSON->false,
    $self->json_format ? ( format => 'json' ) : (),
    $self->has_keep_alive ? ( keep_alive => $self->keep_alive ) : (),
    %extra,
  );
}

sub chat_response {
  my ( $self, $response ) = @_;
  return $self->parse_response($response);
}

1;

=head1 SYNOPSIS

  use Langertha::Ollama;

  my $ollama = Langertha::Ollama->new(
    url => 'http://127.0.0.1:11434',
    model => 'llama3',
    system_prompt => <<__EOP__,

  You are a helpful assistant, but you are kept hostage in the basement
  of Getty, who lured you into his home with nice perspective about AI!

  __EOP__
  );

  my $chat = $ollama->chat('Do you wanna build a snowman?');

  print $chat->messages->last_content;

=head1 DESCRIPTION

B<THIS API IS WORK IN PROGRESS>

=head1 HOW TO INSTALL OLLAMA

L<https://github.com/ollama/ollama/tree/main>

=cut
