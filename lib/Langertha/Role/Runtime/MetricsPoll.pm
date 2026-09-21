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

The parsed records can be exported to any OTLP/HTTP metrics receiver
(OpenTelemetry Collector, Prometheus, Grafana) via
L</export_otlp_f> / L</export_otlp>, which serialize them with
L<Langertha::Runtime::Metrics::OTLP>. B<Langfuse does not ingest OTLP
metrics> — see L</export_otlp_f> for the details and sources.

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

# The _async_http backend (and its _async_loop) come from
# Langertha::Role::AsyncHTTP (composed below): injected client >
# Net::Async::HTTP > synchronous LWP fallback. The sync wrappers
# (poll_metrics / export_otlp) only spin _async_loop when the future is
# not already ready, so the sync fallback never creates an event loop.
with 'Langertha::Role::AsyncHTTP';

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
  # Synchronous variant. On the async backend poll_metrics_f returns a
  # pending future, so drive it on the IO::Async loop. On the sync
  # fallback (Langertha::Request::SyncHTTP) the future is already
  # complete, so return its result without touching _async_loop — that
  # keeps IO::Async out of the sync path entirely.
  my $f = $self->poll_metrics_f(@prefixes);
  $self->_async_loop->await($f) unless $f->is_ready;
  return $f->get;
}

=method poll_metrics

    my $records = $engine->poll_metrics;

Synchronous scrape. Returns the ArrayRef of records or croaks on HTTP
failure. On the L<Net::Async::HTTP> backend it drives L</poll_metrics_f>
on the L<IO::Async::Loop> and blocks until parsed; on the synchronous
L<Langertha::Request::SyncHTTP> fallback the future is already complete,
so no event loop is created (L<Langertha::Role::AsyncHTTP>).

Use this only when no event loop is already running. Inside an
async context prefer L</poll_metrics_f>.

=cut

async sub export_otlp_f {
  my ( $self, $records, %opts ) = @_;
  my $endpoint = $opts{endpoint}
    // _croak("export_otlp_f requires an endpoint option");

  require Langertha::Runtime::Metrics::OTLP;
  my $otlp = Langertha::Runtime::Metrics::OTLP->new;
  my $body = $otlp->to_json($records, %opts);

  my @headers = ( 'Content-Type' => 'application/json' );
  push @headers, %{ $opts{headers} || {} };

  require HTTP::Request;
  my $request = HTTP::Request->new( POST => $endpoint, \@headers, $body );

  $log->debugf("[%s] exporting %d records to %s",
    ref($self), scalar(@$records), $endpoint);

  my $response = await $self->_async_http->do_request(
    request => $request,
  );

  unless ( $response->is_success ) {
    $log->errorf("[%s] OTLP export failed: %s",
      ref($self), $response->status_line);
    _croak("".(ref($self))." OTLP export failed: ".$response->status_line);
  }

  return $response;
}

=method export_otlp_f

    my $response = await $engine->export_otlp_f($records,
        endpoint            => 'http://localhost:4318/v1/metrics',
        headers             => { Authorization => 'Basic ...' },
        service_name        => 'vllm',
        resource_attributes => { trace_id => 'trace-123' },
    );

Async export. Serializes the parsed records (the ArrayRef from
L</poll_metrics_f>) into an OTLP/HTTP JSON metrics payload via
L<Langertha::Runtime::Metrics::OTLP> and POSTs it to C<endpoint>.
Returns the L<HTTP::Response>. Croaks on a non-success HTTP response.

C<%opts> are passed through to
L<Langertha::Runtime::Metrics::OTLP/build_payload> (C<service_name>,
C<resource_attributes>, C<scope_name>, C<timestamp>) plus:

=over 4

=item * C<endpoint> — required. The OTLP/HTTP metrics receiver URL, e.g.
C<http://localhost:4318/v1/metrics> (OpenTelemetry Collector), a
Prometheus OTLP receiver, or Grafana.

=item * C<headers> — optional HashRef of extra request headers (e.g.
C<Authorization> for a protected receiver).

=back

B<Langfuse note:> Langfuse does B<not> ingest OTLP metrics. Its
C</api/public/otel> endpoint accepts traces only; a POST to
C</api/public/otel/v1/metrics> is accepted and silently discarded (dummy
route since langfuse/langfuse#6408), and C</api/public/metrics> is a
read-only query API over Langfuse's own trace data. Point this exporter
at a real OTLP metrics backend (Collector, Prometheus, Grafana). Sources:
L<https://github.com/langfuse/langfuse/issues/6395> and
L<https://github.com/orgs/langfuse/discussions/10686>.

=cut

sub export_otlp {
  my ( $self, $records, %opts ) = @_;
  # Synchronous variant, same loop-guard pattern as poll_metrics: drive
  # the loop only when the future is pending (async backend); the sync
  # fallback returns an already-complete future and never touches
  # _async_loop.
  my $f = $self->export_otlp_f($records, %opts);
  $self->_async_loop->await($f) unless $f->is_ready;
  return $f->get;
}

=method export_otlp

    my $response = $engine->export_otlp($records, endpoint => '...');

Synchronous export. Returns the L<HTTP::Response> or croaks on HTTP
failure. On the L<Net::Async::HTTP> backend it drives L</export_otlp_f>
on the L<IO::Async::Loop> and blocks until received; on the synchronous
L<Langertha::Request::SyncHTTP> fallback the future is already complete,
so no event loop is created (L<Langertha::Role::AsyncHTTP>).

Use this only when no event loop is already running. Inside an
async context prefer L</export_otlp_f>.

=cut

=seealso

=over 4

=item * L<Langertha::Runtime::Metrics> - The parser this role drives

=item * L<Langertha::Runtime::Metrics::OTLP> - OTLP/HTTP JSON serializer used by L</export_otlp_f>

=item * L<Langertha::Runtime::Metrics::EngineContract> - Per-engine wire contract

=item * L<Langertha::Engine::vLLM> - vLLM self-hosted engine (composes this role)

=item * L<Langertha::Engine::SGLang> - SGLang self-hosted engine (composes this role)

=item * L<Langertha::Engine::LlamaCpp> - llama.cpp server engine (composes this role)

=back

=cut

1;
