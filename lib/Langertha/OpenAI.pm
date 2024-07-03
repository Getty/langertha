package Langertha::OpenAI;
# ABSTRACT: OpenAI API

use utf8;
use Moose;
use File::ShareDir::ProjectDistDir qw( :all );
use WWW::Chain;
use Carp qw( croak );
use JSON::MaybeXS;

use Langertha::OpenAI::Chat;
use Langertha::Message;

with 'Langertha::Role::'.$_ for (qw(
  JSON
  UserAgent
  OpenAPI
  Models
  SystemPrompt
  Tools
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
    $self->has_tools ? ( tools => $self->tools_definition ) : (),
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
  use Langertha::Tool;

  my $openai_with_tools = Langertha::OpenAI->new(
    api_key => $ENV{OPENAI_API_KEY},
    system_prompt => "You are a helpful assistant! Use the tools, if necessary.",
    tools => [ Langertha::Tool->new(
      tool_name => 'weather_info',
      tool_description => 'Use this tool to get the weather information of a place.',
      tool_parameters => {
        type => "object",
        properties => {
          place => {
            type => "string",
            description => "Name of the place you want the weather from",
          },
        },
        required => ["place"],
      },
      tool_function => sub {
        my ( $self, %args ) = @_;
        return {
          place => $args{place},
          temperature => '11 Celsius',
          precipitation => '3%',
          humidity => '96%',
          wind => '4,8 km/h',
        };
      },
    ) ],
  );

  my $chat_with_tools = $openai_with_tools->chat('How is the weather in Aachen?');

  print $chat_with_tools->messages->last_content;

=head1 DESCRIPTION

B<THIS API IS WORK IN PROGRESS>

=cut
