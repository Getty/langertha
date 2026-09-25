package Langertha::Role::HTTP;
# ABSTRACT: Role for HTTP APIs
our $VERSION = '0.503';
use Moose::Role;

use Carp qw( croak );
use Log::Any qw( $log );
use Time::HiRes qw( gettimeofday tv_interval );
use URI;
use LWP::UserAgent;
use Encode ();
use File::Spec;

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

# Character strings go on the wire as UTF-8, like the JSON body (json->utf8).
sub _multipart_text {
  my ( $value ) = @_;
  return $value unless defined $value;
  return Encode::encode( 'UTF-8', "$value" );
}

# A filename is path-like: a decoded (UTF-8 flagged) name is encoded, an
# undecoded one is already the filesystem's bytes and passes unchanged.
# RFC 7578 section 4.2: the name goes into filename="..." as raw UTF-8 (what
# browsers and the OpenAI SDKs send), never as filename*.
sub _multipart_filename {
  my ( $name ) = @_;
  return $name unless defined $name && utf8::is_utf8($name);
  return Encode::encode( 'UTF-8', $name );
}

sub generate_multipart_body {
  my ( $self, $req, %args ) = @_;
  my @formdata;
  for my $key ( sort { $a cmp $b } keys %args ) {
    my $value = $args{$key};
    if ( ref $value eq 'ARRAY' && $key =~ /\[\]\z/ ) {
      # Multi-valued field (OpenAI: timestamp_granularities[], include[]):
      # one part per element, in order. -- karr k286
      push @formdata, map { ( $key, _multipart_text($_) ) } @$value;
    }
    elsif ( ref $value eq 'ARRAY' ) {
      # File spec, HTTP::Request::Common form_data convention:
      # [ $path, $filename, @headers ] or [ undef, $filename, Content => $bytes ].
      my ( $file, $filename, @headers ) = @$value;
      $filename = ( File::Spec->splitpath("$file") )[-1]
        if !defined $filename && defined $file;
      push @formdata, $key, [ $file, _multipart_filename($filename), @headers ];
    }
    elsif ( ref $value ) {
      push @formdata, $key, $value;
    }
    else {
      push @formdata, $key, _multipart_text($value);
    }
  }
  return HTTP::Request::Common::form_data(\@formdata, $boundary, $req);
}

=method generate_multipart_body

    my ( $body, $boundary ) = $engine->generate_multipart_body($request, %args);

Encodes C<%args> as a C<multipart/form-data> body (fields sorted by name) and
returns it together with the boundary it used. The boundary is
C<$Langertha::Role::HTTP::boundary> unless a part contains it, in which case
L<HTTP::Request::Common> picks another one; the C<Content-Type> header must use
the returned value (L</generate_http_request> does). Used internally when the
OpenAPI spec specifies C<multipart/form-data> (e.g. audio upload endpoints).

Values are read as follows:

=over

=item * A plain scalar is a text field. It is a character string and is sent
UTF-8 encoded, the same as a value in a JSON body.

=item * An ArrayRef under a key ending in C<[]> (C<timestamp_granularities[]>,
C<include[]>) is a multi-valued field: one text part per element.

=item * Any other ArrayRef is a file part in the L<HTTP::Request::Common>
C<form_data> form: C<[ $path ]>, C<[ $path, $filename, @headers ]>, or
C<< [ undef, $filename, Content => $bytes, @headers ] >> for in-memory content.
The filename defaults to the basename of C<$path>. A decoded (character)
filename is sent UTF-8 encoded; an undecoded one is taken as the filesystem's
bytes and sent unchanged, as raw UTF-8 in C<filename="..."> (RFC 7578).

=back

=cut

sub generate_http_request {
  my ( $self, $method, $url, $response_call, %args ) = @_;
  my $uri = URI->new($url);
  my $content_type = (delete $args{content_type}||"");
  my $userinfo = $uri->userinfo;
  $uri->userinfo(undef) if $userinfo;
  my $headers = [
    # multipart gets its Content-Type below, from the boundary the body used
    $content_type eq 'multipart/form-data' ? ()
      : ( 'Content-Type', 'application/json; charset=utf-8' )
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
    my ( $body, $used_boundary ) = $self->generate_multipart_body($request, %args);
    $request->header( 'Content-Type' => 'multipart/form-data; boundary="'.$used_boundary.'"' );
    $request->content($body);
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

our $error_body_max_length = 500;

sub _error_response_body {
  my ( $self, $response ) = @_;
  my $body = eval { $response->decoded_content };
  $body = $response->content unless defined $body && length $body;
  return '' unless defined $body && length $body;
  $body =~ s/\s+/ /g;
  $body =~ s/\A\s+//;
  $body =~ s/\s+\z//;
  return '' unless length $body;
  if ( length($body) > $error_body_max_length ) {
    $body = substr($body, 0, $error_body_max_length) . '...';
  }
  return $body;
}

sub parse_response {
  my ( $self, $response ) = @_;
  unless ($response->is_success) {
    my $body = $self->_error_response_body($response);
    $log->errorf("[%s] HTTP %s", ref $self, $response->status_line);
    croak "".(ref $self)." request failed: ".($response->status_line)
      .( length $body ? " - ".$body : "" );
  }
  $self->_update_rate_limit($response) if $self->can('_update_rate_limit');
  $log->tracef("[%s] Response: %s", ref $self, $response->decoded_content);
  return $self->json->decode($response->content);
}

=method parse_response

    my $data = $engine->parse_response($http_response);

Decodes a successful L<HTTP::Response> body as JSON and returns the data
structure. On failure croaks with the HTTP status line, and appends the
provider's response body (whitespace-collapsed and truncated to
C<$error_body_max_length> characters) so the real cause — e.g. a provider
JSON error object — is visible in the croak message. If the engine supports
rate limiting, extracts rate limit headers via C<_update_rate_limit> before
decoding the body.

=cut

has user_agent_timeout => (
  isa => 'Int',
  is => 'ro',
  predicate => 'has_user_agent_timeout',
);

=attr user_agent_timeout

Optional timeout in seconds for HTTP requests. The synchronous methods get it
through the L<LWP::UserAgent> (seconds without activity on the connection);
when not set, LWP's own default (180 seconds) applies there.

The C<_f> methods (and L<Langertha::Role::AsyncHTTP/async_request_f>) on the
L<Net::Async::HTTP> backend apply it as well: a plain request fails after this
many seconds in total, a streaming one after this many seconds without a byte
(a long stream that keeps delivering is not cut off). The Future then fails
with C<< <engine class>: request to <url> timed out after Ns >> (C<streaming
request ... without data (...)> for a stream), the URL without its query
string, and the Net::Async::HTTP category (C<timeout> / C<stall_timeout>) as
the second failure value. When not set, the async backend has B<no> timeout,
as before. The synchronous fallback uses the L<LWP::UserAgent>'s timeout; an
injected client that is not a L<Net::Async::HTTP> keeps its own.

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

  my $t0 = [gettimeofday];
  my $response = $self->user_agent->request($request);

  unless ($response->is_success) {
    my $body = $self->_error_response_body($response);
    croak "".(ref $self)." streaming request failed: ".($response->status_line)
      .( length $body ? " - ".$body : "" );
  }

  my $chunks = $self->process_stream_data($response->content, $chunk_callback);
  my $total_seconds = tv_interval($t0);

  # This path reads the whole stream with one blocking LWP request before
  # process_stream_data runs, so a true TTFT (time to first token) is
  # not observable here; only end-to-end wall-clock. Consumers that need
  # TTFT should use L<Langertha::Role::Chat/simple_chat_stream_realtime_f>,
  # which delivers chunks as they arrive on either backend of
  # L<Langertha::Role::AsyncHTTP> (Net::Async::HTTP, or LWP's content
  # callback on the synchronous fallback).
  return ($chunks, { total_seconds => $total_seconds });
}

=method execute_streaming_request

    my ($chunks, $timing) = $engine->execute_streaming_request($request, $chunk_callback);
    my ($chunks, $timing) = $engine->execute_streaming_request($request);

Executes a streaming HTTP request synchronously using L<LWP::UserAgent> and
delegates stream parsing to L<Langertha::Role::Streaming/process_stream_data>.
Requires the engine to also compose L<Langertha::Role::Streaming>. On a
non-success response croaks with the HTTP status line and the provider's
response body appended (whitespace-collapsed and length-limited), mirroring
L</parse_response>. Returns an
ArrayRef of L<Langertha::Stream::Chunk> objects and a timing HashRef with
C<total_seconds> (Float, seconds). C<ttft_seconds> is omitted because this
method reads the whole body before parsing — use
L<Langertha::Role::Chat/chat_stream_realtime_f> for true TTFT (it streams
incrementally on both backends of L<Langertha::Role::AsyncHTTP>, including the
synchronous LWP fallback). If C<$chunk_callback> is provided it is called with each chunk
as it is parsed.

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
