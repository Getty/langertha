package Langertha::Role::HTTP;
# ABSTRACT: Role for HTTP APIs
our $VERSION = '0.301';
use Moose::Role;

use Carp qw( croak );
use Log::Any qw( $log );
use URI;
use LWP::UserAgent;

use Langertha::Request::HTTP;
use HTTP::Request::Common;

requires qw(
  json
);

has url => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_url',
);

=attr url

Base URL for API requests. Optional — many engines hard-code their default URL
internally and only require this attribute to be set when pointing at a custom
or self-hosted endpoint.

=cut

sub generate_json_body {
  my ( $self, %args ) = @_;
  return $self->json->encode({ %args });
}

=method generate_json_body

    my $body = $engine->generate_json_body(%args);

Encodes C<%args> as a JSON string using the engine's L<Langertha::Role::JSON/json>
instance. Used internally when building C<application/json> request bodies.

=cut

our $boundary = 'XyXLaXyXngXyXerXyXthXyXaXyX';

sub generate_multipart_body {
  my ( $self, $req, %args ) = @_;
  my @formdata = map { $_, $args{$_} } sort { $a cmp $b } keys %args;
  return HTTP::Request::Common::form_data(\@formdata, $boundary, $req);
}

=method generate_multipart_body

    my $body = $engine->generate_multipart_body($request, %args);

Encodes C<%args> as a C<multipart/form-data> body and attaches it to C<$request>.
Used internally when the OpenAPI spec specifies C<multipart/form-data> content type
(e.g. for audio upload endpoints).

=cut

sub generate_http_request {
  my ( $self, $method, $url, $response_call, %args ) = @_;
  my $uri = URI->new($url);
  my $content_type = (delete $args{content_type}||"");
  my $userinfo = $uri->userinfo;
  $uri->userinfo(undef) if $userinfo;
  my $headers = [
    ( 'Content-Type',
      $content_type eq 'multipart/form-data'
        ? 'multipart/form-data; boundary="'.$boundary.'"'
      : 'application/json; charset=utf-8' )
  ];
  my $request = Langertha::Request::HTTP->new(
    http => [ uc($method), $uri, $headers, ( scalar %args > 0 ?
      ( !$content_type or $content_type eq 'application/json' )
        ? $self->generate_json_body(%args)
          : ()
      : ()
    ) ],
    request_source => $self,
    response_call => $response_call,
  );
  if ($content_type and $content_type eq 'multipart/form-data') {
    $request->content($self->generate_multipart_body($request, %args));
  }
  if ($userinfo) {
    my ( $user, $pass ) = split(/:/, $userinfo);
    if ($user and $pass) {
      $request->authorization_basic($user, $pass);
    }
  }
  $self->update_request($request) if $self->can('update_request');
  return $request;
}

=method generate_http_request

    my $request = $engine->generate_http_request(
        $method, $url, $response_call, %args
    );

Low-level HTTP request builder. Creates a L<Langertha::Request::HTTP> object
with the appropriate headers and body encoding (JSON or multipart). Calls the
engine's C<update_request> hook if it exists, allowing engines to inject
authentication headers. If the URL contains C<user:password> userinfo, HTTP
Basic authentication is set automatically.

=cut

sub parse_response {
  my ( $self, $response ) = @_;
  unless ($response->is_success) {
    $log->errorf("[%s] HTTP %s", ref $self, $response->status_line);
    croak "".(ref $self)." request failed: ".($response->status_line);
  }
  $self->_update_rate_limit($response) if $self->can('_update_rate_limit');
  $log->tracef("[%s] Response: %s", ref $self, $response->decoded_content);
  return $self->json->decode($response->decoded_content);
}

=method parse_response

    my $data = $engine->parse_response($http_response);

Decodes a successful L<HTTP::Response> body as JSON and returns the data
structure. Croaks with the HTTP status line on failure. If the engine
supports rate limiting, extracts rate limit headers via
C<_update_rate_limit> before decoding the body.

=cut

has user_agent_timeout => (
  isa => 'Int',
  is => 'ro',
  predicate => 'has_user_agent_timeout',
);

=attr user_agent_timeout

Optional timeout in seconds for the L<LWP::UserAgent>. When not set, the
default L<LWP::UserAgent> timeout applies.

=cut

has user_agent_agent => (
  isa => 'Str',
  is => 'ro',
  lazy_build => 1,
);
sub _build_user_agent_agent {
  my ( $self ) = @_;
  return "".(ref $self)."";
}

=attr user_agent_agent

The C<User-Agent> string sent with HTTP requests. Defaults to the engine's
class name.

=cut

has user_agent => (
  isa => 'LWP::UserAgent',
  is => 'ro',
  lazy_build => 1,
);
sub _build_user_agent {
  my ( $self ) = @_;
  return LWP::UserAgent->new(
    agent => $self->user_agent_agent,
    $self->has_user_agent_timeout ? ( timeout => $self->user_agent_timeout ) : (),
  );
}

=attr user_agent

The L<LWP::UserAgent> instance used for synchronous HTTP requests. Built lazily
with C<user_agent_agent> and C<user_agent_timeout>.

=cut

sub execute_streaming_request {
  my ($self, $request, $chunk_callback) = @_;

  croak "execute_streaming_request requires Langertha::Role::Streaming"
    unless $self->does('Langertha::Role::Streaming');

  my $response = $self->user_agent->request($request);

  croak "".(ref $self)." streaming request failed: ".($response->status_line)
    unless $response->is_success;

  return $self->process_stream_data($response->decoded_content, $chunk_callback);
}

=method execute_streaming_request

    my $chunks = $engine->execute_streaming_request($request, $chunk_callback);
    my $chunks = $engine->execute_streaming_request($request);

Executes a streaming HTTP request synchronously using L<LWP::UserAgent> and
delegates stream parsing to L<Langertha::Role::Streaming/process_stream_data>.
Requires the engine to also compose L<Langertha::Role::Streaming>. Returns an
ArrayRef of L<Langertha::Stream::Chunk> objects. If C<$chunk_callback> is
provided it is called with each chunk as it is parsed.

=cut

=seealso

=over

=item * L<Langertha::Role::JSON> - JSON encoding/decoding (required by this role)

=item * L<Langertha::Role::Streaming> - Stream processing

=item * L<Langertha::Role::OpenAPI> - OpenAPI request generation

=item * L<Langertha::Request::HTTP> - HTTP request object created by this role

=back

=cut

1;
