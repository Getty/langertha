package Langertha::Engine::AKI;
# ABSTRACT: AKI.IO native API
our $VERSION = '0.101';
use Moose;
use Carp qw( croak );
use JSON::MaybeXS;

with 'Langertha::Role::'.$_ for (qw(
  JSON
  HTTP
  Models
  Temperature
  SystemPrompt
  Chat
));

has api_key => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_AKI_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_AKI_API_KEY or api_key set";
}

has '+url' => (
  lazy => 1,
  default => sub { 'https://aki.io' },
);
sub has_url { 1 }

sub default_model { 'llama3_8b_chat' }

has top_k => (
  is => 'ro',
  isa => 'Num',
  predicate => 'has_top_k',
);

has top_p => (
  is => 'ro',
  isa => 'Num',
  predicate => 'has_top_p',
);

has max_gen_tokens => (
  is => 'ro',
  isa => 'Int',
  predicate => 'has_max_gen_tokens',
);

# Dynamic model listing

sub list_models_request {
  my ($self) = @_;
  return $self->generate_http_request(
    GET => $self->url.'/api/endpoints?key='.$self->api_key,
    sub { $self->list_models_response(shift) },
  );
}

sub list_models_response {
  my ($self, $response) = @_;
  my $data = $self->parse_response($response);
  return $data->{endpoints};
}

sub list_models {
  my ($self, %opts) = @_;

  # Check cache unless force_refresh requested
  unless ($opts{force_refresh}) {
    my $cache = $self->_models_cache;
    if ($cache->{timestamp} && time - $cache->{timestamp} < $self->models_cache_ttl) {
      return $opts{full} ? $cache->{models} : $cache->{model_ids};
    }
  }

  # Fetch from API
  my $request = $self->list_models_request;
  my $response = $self->user_agent->request($request);
  my $endpoints = $request->response_call->($response);

  # Update cache
  $self->_models_cache({
    timestamp => time,
    models => $endpoints,
    model_ids => $endpoints,
  });

  return $endpoints;
}

sub endpoint_details_request {
  my ($self, $endpoint_name) = @_;
  return $self->generate_http_request(
    GET => $self->url.'/api/endpoints/'.$endpoint_name.'?key='.$self->api_key,
    sub { $self->endpoint_details_response(shift) },
  );
}

sub endpoint_details_response {
  my ($self, $response) = @_;
  return $self->parse_response($response);
}

sub endpoint_details {
  my ($self, $endpoint_name) = @_;
  my $request = $self->endpoint_details_request($endpoint_name);
  my $response = $self->user_agent->request($request);
  return $request->response_call->($response);
}

# Chat

sub chat_request {
  my ( $self, $messages, %extra ) = @_;
  my $model = $self->chat_model;
  return $self->generate_http_request(
    POST => $self->url.'/api/call/'.$model,
    sub { $self->chat_response(shift) },
    key => $self->api_key,
    chat_context => $self->json->encode($messages),
    $self->has_temperature ? ( temperature => $self->temperature ) : (),
    $self->has_top_k ? ( top_k => $self->top_k ) : (),
    $self->has_top_p ? ( top_p => $self->top_p ) : (),
    $self->has_max_gen_tokens ? ( max_gen_tokens => $self->max_gen_tokens ) : (),
    wait_for_result => JSON->true,
    %extra,
  );
}

sub chat_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  croak "".(ref $self)." API error: ".($data->{error} || 'unknown')
    unless $data->{success};
  require Langertha::Response;
  return Langertha::Response->new(
    content       => $data->{text} // '',
    raw           => $data,
    $data->{model_name} ? ( model => $data->{model_name} ) : (),
    $data->{total_duration} ? ( timing => { total_duration => $data->{total_duration} } ) : (),
  );
}

sub openai {
  my ( $self, %args ) = @_;
  require Langertha::Engine::AKIOpenAI;
  return Langertha::Engine::AKIOpenAI->new(
    model => $self->model,
    api_key => $self->api_key,
    $self->has_system_prompt ? ( system_prompt => $self->system_prompt ) : (),
    $self->has_temperature ? ( temperature => $self->temperature ) : (),
    %args,
  );
}

__PACKAGE__->meta->make_immutable;

=head1 SYNOPSIS

  use Langertha::Engine::AKI;

  my $aki = Langertha::Engine::AKI->new(
    api_key => $ENV{AKI_API_KEY},
    model   => 'llama3_8b_chat',
  );

  print $aki->simple_chat('Hello from Perl!');

  # Get OpenAI-compatible API access
  my $aki_openai = $aki->openai;
  print $aki_openai->simple_chat('Hello via OpenAI format!');

=head1 DESCRIPTION

This module provides access to AKI.IO's native API for running LLM inference.

B<AKI.IO is a European AI model hub based in Germany.> All inference runs
on EU-based infrastructure, fully compliant with GDPR and European data
protection regulations. No data leaves the EU. This makes AKI.IO an ideal
choice for applications with data sovereignty requirements.

AKI.IO hosts open-source models and provides both a native API and an
OpenAI-compatible API.

B<Native API features:>

=over 4

=item * Chat completions

=item * Synchronous responses (C<wait_for_result>)

=item * Temperature, top_k, top_p, max_gen_tokens controls

=item * Dynamic endpoint/model listing via C<list_models()>

=item * Endpoint details via C<endpoint_details()>

=item * OpenAI-compatible API access via C<openai()> method

=back

B<Auth:> API key is sent as a C<key> field in the JSON request body
(not as an HTTP header).

B<Streaming:> The native API uses job-based polling for streaming,
which is not yet implemented. For streaming, use the OpenAI-compatible
endpoint via C<< $aki->openai >>.

B<THIS API IS WORK IN PROGRESS>

=attr api_key

The AKI.IO API key. If not provided at construction time, reads from
the C<LANGERTHA_AKI_API_KEY> environment variable. Required.

Unlike OpenAI-compatible engines, the AKI native API sends the key as
a C<key> field in the JSON request body rather than as an HTTP header.

=attr top_k

  top_k => 40

Top-K sampling parameter. Controls the number of highest-probability
tokens to consider for each generation step.

=attr top_p

  top_p => 0.9

Top-P (nucleus) sampling parameter. Controls the cumulative probability
threshold for token selection.

=attr max_gen_tokens

  max_gen_tokens => 1000

Maximum number of tokens to generate in the response.

=method list_models

  my $endpoints = $aki->list_models;
  # Returns: ['llama3_8b_chat', 'flux_schnell', ...]

  my $endpoints = $aki->list_models(force_refresh => 1);  # Bypass cache

Fetches available endpoint names from the AKI.IO C<GET /api/endpoints> API.
Results are cached for 1 hour (configurable via C<models_cache_ttl>).

=method endpoint_details

  my $details = $aki->endpoint_details('llama3_8b_chat');
  # Returns hashref with name, title, description, workers, parameter_description, etc.

Fetches detailed information about a specific endpoint from the AKI.IO
C<GET /api/endpoints/{name}> API. Returns worker info, model metadata,
and parameter descriptions.

=method chat_request

  my $request = $aki->chat_request($messages, %extra);

Generates a native AKI.IO chat request. Posts to C</api/call/{model}>
with the messages encoded as JSON in the C<chat_context> field. Includes
C<key>, C<temperature>, C<top_k>, C<top_p>, C<max_gen_tokens>, and
C<wait_for_result> parameters as set. Returns an HTTP request object.

=method chat_response

  my $response = $aki->chat_response($http_response);

Parses a native AKI.IO chat response. Dies with an API error message if
C<success> is false. Returns a L<Langertha::Response> with C<content>,
C<model>, C<timing>, and C<raw>.

=method openai

  my $oai = $aki->openai;
  my $oai = $aki->openai(model => 'different_model');

Returns a L<Langertha::Engine::AKIOpenAI> instance configured with
the same API key, model, and settings. Supports all OpenAI-compatible
features including streaming and tool calling.

=head1 GETTING AN API KEY

Sign up at L<https://aki.io/> and generate an API key.

Set the environment variable:

  export AKI_API_KEY=your-key-here
  # Or use LANGERTHA_AKI_API_KEY

=seealso L<Langertha::Engine::AKIOpenAI>, L<https://aki.io/docs>, L<Langertha>

=cut
