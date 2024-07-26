package Langertha::Engine::OpenAI;
# ABSTRACT: OpenAI API

use utf8;
use Moose;
use File::ShareDir::ProjectDistDir qw( :all );
use WWW::Chain;
use Carp qw( croak );
use JSON::MaybeXS;

with 'Langertha::Role::'.$_ for (qw(
  JSON
  UserAgent
  HTTP
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
  return $ENV{LANGERTHA_OPENAI_API_KEY}
    || $ENV{OPENAI_API_KEY}
    || croak "".(ref $self)." requires OPENAI_API_KEY";
}

sub update_request {
  my ( $self, $request ) = @_;
  $request->header('Authorization', 'Bearer '.$self->api_key);
}

sub default_model { 'gpt-3.5-turbo' }
sub default_embedding_model { 'text-embedding-3-small' }

sub openapi_file { yaml => dist_file('Langertha','openai.yaml') };

sub embedding_request {
  my ( $self, $input, %extra ) = @_;
  return $self->generate_request( createEmbedding => sub { $self->embedding_response(shift) },
    model => $self->embedding_model,
    input => $input,
    %extra,
  );
}

sub embedding_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  # tracing
  return $data;
}

sub chat_request {
  my ( $self, $messages, %extra ) = @_;
  return $self->generate_request( createChatCompletion => sub { $self->chat_response(shift) },
    model => $self->model,
    messages => $messages,
    stream => JSON->false,
    # $self->has_seed ? ( seed => $self->seed )
    #   : $self->randomize_seed ? ( seed => round(rand(100_000_000)) ) : (),
    %extra,
  );
}

sub chat_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  # tracing
  my @messages = map { $_->{message} } @{$data->{choices}};
  return $messages[0]->{content};
}

1;

=head1 SYNOPSIS

  use Langertha::OpenAI;

=head1 DESCRIPTION

B<THIS API IS WORK IN PROGRESS>

=head1 HOW TO GET OPENAI API KEY

L<https://platform.openai.com/docs/quickstart>

=cut
