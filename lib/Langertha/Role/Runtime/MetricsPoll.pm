package Langertha::Role::Runtime::MetricsPoll;
# ABSTRACT: Async Prometheus /metrics scraper for self-hosted engines
our $VERSION = '0.503';
use Moose::Role;
use Future::AsyncAwait;
use Log::Any qw( $log );
use URI;
use Carp qw( croak );

use Langertha::Runtime::Metrics;

requires qw(
  json
  url
);

=head1 SYNOPSIS

    use Langertha::Engine::vLLM;

    my $vllm = Langertha::Engine::vLLM->new(
        url => 'http://localhost:8000/v1',
    );

    # Async — preferred for live systems
    my $records = await $vllm->poll_metrics_f;
    # Returns: [ { name => 'vllm:num_requests_running', type => 'gauge',
    #              value => 3, labels => { model_name => 'Qwen/...' } }, ... ]

    # Sync wrapper
    my $records = $vllm->poll_metrics;

=head1 DESCRIPTION

Composes onto self-hosted engines that expose a Prometheus
C<GET /metrics> endpoint at the server's C<url> attribute. The role
scrapes the body, parses it via L<Langertha::Runtime::Metrics>, and
returns the parsed ArrayRef. No filtering is applied by default —
pass a prefix to L</poll_metrics_f($prefix)> or filter with
L<Langertha::Runtime::Metrics/filter_prefix> downstream.

The endpoint path is derived by stripping the trailing C</v1> (or
any trailing slash) from C<url>, then appending C</metrics>. Engines
whose C<url> is e.g. C<http://localhost:8000/v1> therefore hit
C<http://localhost:8000/metrics> — matching the convention used by
vLLM, SGLang, and llama.cpp's built-in server.

B<Authentication:> None. These are local servers; no C<api_key>
header is sent. If a deployment sits behind auth, layer it on
externally (proxy or L<Langertha::Role::HTTP/generate_http_request>
extension).

B<Ollama> is intentionally B<not> composed with this role:
Ollama's runtime stats live at C</api/ps> in JSON, not
C</metrics> in Prometheus text. See
L<Langertha::Runtime::Metrics::EngineContract> for the wire
contract and the follow-up karr ticket tracked alongside that
document for the JSON-to-Prometheus adapter work.

=cut

sub metrics_url {
  my ( $self ) = @_;
  croak "metrics_url requires a url attribute" unless $self->has_url;
  my $uri = URI->new($self->url);
  my $path = $uri->path;
  # Strip a trailing /v1 (and any preceding slash) so we get the bare
  # server root before appending /metrics. /v1 is the OpenAI-compatible
  # base; /metrics lives at the root for vLLM, SGLang, llama.cpp.
  $path =~ s{/v1/?$}{/};
  $path = '/' unless length $path;
  $uri->path($path . 'metrics');
  return $uri->as_string;
}

=method metrics_url

    my $url = $engine->metrics_url;

Derives the C</metrics> URL from the engine's C<url> attribute by
stripping the trailing C</v1>. Returns the full URL as a string.

=cut

sub _croak {
  my ($msg) = @_;
  croak($msg);
}

# Private IO::Async loop + Net::Async::HTTP for the async path. Same
# pattern as Langertha::Role::Chat: lazy-loaded on first call, lives
# on the engine instance, attached to a private loop.
has _async_loop => (
  is => 'ro',
  lazy_build => 1,
);

sub _build__async_loop {
  require IO::Async::Loop;
  return IO::Async::Loop->new;
}

has _async_http => (
  is => 'ro',
  lazy_build => 1,
);

sub _build__async_http {
  my ($self) = @_;
  require Net::Async::HTTP;
  my $http = Net::Async::HTTP->new;
  $self->_async_loop->add($http);
  return $http;
}

async sub poll_metrics_f {
  my ( $self, @prefixes ) = @_;

  my $url = $self->metrics_url;
  $log->debugf("[%s] scraping %s", ref($self), $url);

  require HTTP::Request;
  my $request = HTTP::Request->new(GET => $url);

  my $response = await $self->_async_http->do_request(
    request => $request,
  );

  unless ( $response->is_success ) {
    $log->errorf("[%s] /metrics fetch failed: %s",
      ref($self), $response->status_line);
    _croak("".(ref($self))." /metrics fetch failed: ".$response->status_line);
  }

  my $body = $response->decoded_content // $response->content;
  return Langertha::Runtime::Metrics->new
    ->parse_and_filter($body, @prefixes);
}

=method poll_metrics_f

    my $records = await $engine->poll_metrics_f;
    my $vllm    = await $engine->poll_metrics_f('vllm:');

Async scrape. Returns a Future that resolves to the ArrayRef of
parsed L<Langertha::Runtime::Metrics> records. Optional prefix
arguments OR-filter the parser output (see
L<Langertha::Runtime::Metrics/parse_and_filter>).

Croaks on a non-success HTTP response.

=cut

sub poll_metrics {
  my ( $self, @prefixes ) = @_;
  # Synchronous variant. Spins up a private IO::Async loop on the
  # same Net::Async::HTTP client as the async path and blocks until
  # the response is parsed. LWP would be simpler but introduces a
  # second transport just for this method.
  my $loop = $self->_async_loop;
  my $records = $loop->await(
    Future->wrap(
      $self->poll_metrics_f(@prefixes)
    )
  );
  return $records;
}

=method poll_metrics

    my $records = $engine->poll_metrics;

Synchronous scrape. Drives L</poll_metrics_f> on a private
L<IO::Async::Loop> and blocks until the response is parsed.
Returns the ArrayRef of records or croaks on HTTP failure.

Use this only when no event loop is already running. Inside an
async context prefer L</poll_metrics_f>.

=cut

=seealso

=over 4

=item * L<Langertha::Runtime::Metrics> - The parser this role drives

=item * L<Langertha::Runtime::Metrics::EngineContract> - Per-engine wire contract

=item * L<Langertha::Engine::vLLM> - vLLM self-hosted engine (composes this role)

=item * L<Langertha::Engine::SGLang> - SGLang self-hosted engine (composes this role)

=item * L<Langertha::Engine::LlamaCpp> - llama.cpp server engine (composes this role)

=back

=cut

1;
