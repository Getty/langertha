package Langertha::OpenAI;
# ABSTRACT: OpenAI API

use Moose;
use File::ShareDir::ProjectDistDir qw( :all );
use WWW::Chain;
use Carp qw( croak );
use JSON::MaybeXS;

use Langertha::OpenAI::Chat;

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

sub embedding {
  my ( $self, $input, %extra ) = @_;
}

sub embedding_request {
  my ( $self, $input, %extra ) = @_;
  return $self->generate_request( createEmbedding =>
    model => $self->embedding_model,
    input => $input,
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
  return Langertha::OpenAI::Chat->new(
    openai => $self,
    %args,
  );
}

sub chat_request {
  my ( $self, $messages, %extra ) = @_;
  return $self->generate_request( createChatCompletion =>
    model => $self->model,
    messages => $messages->to_api,
    stream => JSON->false,
    %extra,
  );
}
sub chat_response {
  my ( $self, $response ) = @_;
  return $self->parse_response($response);
}

1;

=head1 SYNOPSIS

  use Langertha::OpenAI;

  my $openai = Langertha::OpenAI->new(
    api_key => 'xx-proj-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
    model => 'gpt-3.5-turbo',
    system_prompt => <<__EOP__,

  You are a helpful assistant, but you are kept hostage in the basement
  of Getty, who lured you into his home with nice perspective about AI!

  __EOP__
  );

  my $chat = $openai->chat('Do you wanna build a snowman?');

  print $chat->messages->last_content;

=head1 DESCRIPTION

B<THIS API IS WORK IN PROGRESS>

=cut
