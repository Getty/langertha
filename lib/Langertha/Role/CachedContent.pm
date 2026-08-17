package Langertha::Role::CachedContent;
# ABSTRACT: Role for the explicit cachedContent resource lifecycle (create/get/list/update/delete)
our $VERSION = '0.503';
use Moose::Role;
use Future::AsyncAwait;
use Carp qw( croak );
use Langertha::CachedContent;

# The consumer's endpoint/auth seam (Langertha::Engine::Gemini's
# gemini_endpoint / gemini_url, ADR 0016 decision 3, karr #88, #94). These are
# plain subs, installed at compile time, so they are already present when the
# engine's runtime `with` executes — `requires` holds and fails at composition
# rather than at the first HTTP call.
#
# The name is deliberately Gemini's own rather than a neutral alias: the
# cachedContents lifecycle *is* the Gemini Generative Language REST surface,
# so any engine that can compose this role speaks that dialect and brings
# those methods. A provider-neutral indirection would be an abstraction with
# one implementation and no second caller to justify it.
requires qw(
  gemini_endpoint
  gemini_url
);

# No `requires` for user_agent / json: those are defined as attributes on the
# engine *after* role composition, so requiring them at composition time would
# fail. The role methods do `$self->can($m)` guards instead (see
# _assert_http_seam below; matches how Langertha::Role::Tools handles optional
# cross-role seams).

=head1 SYNOPSIS

    with 'Langertha::Role::CachedContent';

    my $cc = $engine->create_cached_content_f(
        model              => 'models/gemini-2.5-pro',
        system_instruction => 'You are a careful reviewer.',
        ttl                => '300s',
        contents           => [ { role => 'user', parts => [ { text => 'long prompt...' } ] } ],
    );
    # Returns a Langertha::CachedContent with name set

    my $same = await $engine->get_cached_content_f( $cc->name );
    my @all  = await $engine->list_cached_contents_f;
    await $engine->update_cached_content_f( $cc->name, ttl => '600s' );
    await $engine->delete_cached_content_f( $cc->name );

=head1 DESCRIPTION

Lifecycle wrapper around the Gemini explicit C<cachedContent> resource
(L<https://ai.google.dev/api/caching>). Composed by engines that want to
expose resource management (currently L<Langertha::Engine::Gemini>) —
the methods are B<role methods>, not engine methods, so any other engine
with the same REST surface can compose the role rather than re-implement
it.

Endpoints, C<{base}> being the consumer's
L<Langertha::Engine::Gemini/gemini_endpoint> (C<< {url}/v1beta >> on the
Developer API):

=over

=item * C<POST   {base}/cachedContents>              — create
=item * C<GET    {base}/cachedContents>              — list (paginated)
=item * C<GET    {base}/cachedContents/{name}>       — get
=item * C<PATCH  {base}/cachedContents/{name}>       — update (expiration only)
=item * C<DELETE {base}/cachedContents/{name}>       — delete

=back

All methods are async via L<Future::AsyncAwait>. The sync L<Langertha::Role::Chat>
wrappers (L</create_cached_content>, etc.) delegate to the async versions
through the engine's L<IO::Async> loop when one is wired up; otherwise
they run synchronously.

The role owns the resource paths and the HTTP plumbing only. Base URL, API
version and the credential are the consumer's — every request URL is built by
the required C<gemini_endpoint> / C<gemini_url> seam
(L<Langertha::Engine::Gemini>, ADR 0016 decision 3), so a subclass that moves
the endpoint or the auth scheme moves the whole cachedContents lifecycle with
it. The role does B<not>
introspect model names or filter by generation. Engines narrow
C<Langertha::Engine::Gemini>'s advertising of the capability per model
family (see L<Langertha::Engine::Gemini>'s C<around engine_capabilities>).

=cut

# The role owns the resource *paths* only. Base URL, API version and the
# credential all come from the consumer's seam, so a subclass that moves any
# of them (header auth, /v1, another base path) moves the whole cachedContents
# lifecycle with it instead of being half converted.
#
# cachedContents is its own top-level collection, not a sub-resource of
# models/ — hence gemini_url / gemini_endpoint, never gemini_model_url.
sub _cached_contents_path { 'cachedContents' }

sub _cached_content_path {
  my ( $self, $name ) = @_;
  croak "name must look like cachedContents/{id}; got '$name'"
    unless defined $name && $name =~ m{\AcachedContents/[^/\s]+\z};
  return $name;
}

# Credential-free resource URLs, for callers that want to name a cache rather
# than fetch it; the request sites below go through gemini_url, which is what
# places the credential.
sub _cached_contents_url {
  my ( $self ) = @_;
  return $self->gemini_endpoint( $self->_cached_contents_path );
}

# Guard: the engine must expose the HTTP / JSON seams the role uses to talk
# to the cachedContents REST surface. Composed on Engine::Gemini (which
# extends Engine::Remote -> composes Role::HTTP -> Role::JSON) so this
# passes; it croaks loudly when the role is composed on an engine without the
# right surface — better than a "method not found" later.
#
# url and api_key are deliberately NOT on this list: the role no longer reads
# either, it asks the required gemini_endpoint / gemini_url for the finished
# URL. A consumer that authenticates without an api_key attribute at all
# (ADC bearer token, mTLS) is a legitimate consumer of this role.
sub _assert_http_seam {
  my ( $self ) = @_;
  for my $m (qw( user_agent generate_http_request parse_response json )) {
    croak "Langertha::Role::CachedContent: consumer must provide '$m'"
      unless $self->can($m);
  }
}

sub _cached_content_url {
  my ( $self, $name ) = @_;
  return $self->gemini_endpoint( $self->_cached_content_path($name) );
}

# Strip the leading "cachedContents/" so callers can pass either a bare
# id or the full resource name uniformly.
sub _normalize_name {
  my ( $class, $name ) = @_;
  return undef unless defined $name;
  $name =~ s{\AcachedContents/}{};
  return 'cachedContents/' . $name;
}

=method create_cached_content_f

    my $cc = await $engine->create_cached_content_f(
        model              => 'models/gemini-2.5-pro',
        ttl                => '300s',
        system_instruction => 'be brief',
        contents           => [ ... ],
        tools              => [ ... ],          # optional
        display_name       => 'reviewer',       # optional
    );
    # $cc is a Langertha::CachedContent with name set

Posts to the C<cachedContents> collection (C<POST /v1beta/cachedContents> on
the Developer API), parses the response into a
L<Langertha::CachedContent>. Accepts either a pre-built
L<Langertha::CachedContent> (the role will call C<to_create_body> for
you) or the individual named attributes.

Returns the persisted CachedContent.

=cut

async sub create_cached_content_f {
  my ( $self, @args ) = @_;

  $self->_assert_http_seam;

  my $cc;
  if ( @args == 1 && ref( $args[0] ) && eval { $args[0]->isa('Langertha::CachedContent') } ) {
    $cc = $args[0];
  }
  else {
    $cc = Langertha::CachedContent->new( @args );
  }

  my $url = $self->gemini_url( $self->_cached_contents_path );
  my $body = $cc->to_create_body;

  my $req = $self->generate_http_request(
    POST => $url,
    sub { $self->_parse_cached_content_response(shift) },
    %$body,
  );

  my $http_res = $self->user_agent->request($req);
  return $req->response_call->($http_res);
}

=method create_cached_content

    my $cc = $engine->create_cached_content(%same_args);

Sync wrapper around L</create_cached_content_f>.

=cut

sub create_cached_content {
  my ( $self, @args ) = @_;
  return $self->create_cached_content_f(@args)->get;
}

=method get_cached_content_f

    my $cc = await $engine->get_cached_content_f('cachedContents/abc123');
    my $cc = await $engine->get_cached_content_f('abc123');          # bare id accepted

Fetch a single cache by C<name> (or bare id).

=cut

async sub get_cached_content_f {
  my ( $self, $name ) = @_;
  $self->_assert_http_seam;
  $name = $self->_normalize_name($name);

  my $url = $self->gemini_url( $self->_cached_content_path($name) );
  my $req = $self->generate_http_request(
    GET => $url,
    sub { $self->_parse_cached_content_response(shift) },
  );

  my $http_res = $self->user_agent->request($req);
  return $req->response_call->($http_res);
}

sub get_cached_content {
  my ( $self, $name ) = @_;
  return $self->get_cached_content_f($name)->get;
}

=method list_cached_contents_f

    my @caches = await $engine->list_cached_contents_f;
    my @page   = await $engine->list_cached_contents_f(page_size => 50);

Returns a list of L<Langertha::CachedContent>. Walks pagination
automatically (L<https://ai.google.dev/api/caching#method:-cachedcontents.list>).
Accepts C<page_size> and C<page_token> for one-page control.

=cut

async sub list_cached_contents_f {
  my ( $self, %opts ) = @_;
  $self->_assert_http_seam;

  my @all;
  my $token = $opts{page_token};
  my $page_size = $opts{page_size};

  do {
    my $url = $self->gemini_url( $self->_cached_contents_path );

    # Pagination goes on with URI rather than through the seam's query list:
    # pageToken is opaque server data that has to be percent-encoded, whereas
    # the seam interpolates verbatim (it carries the credential and fixed
    # switches like alt=sse). Same handling as
    # Langertha::Engine::Gemini::list_models_request.
    my %params;
    $params{pageSize}  = $page_size if defined $page_size;
    $params{pageToken} = $token     if defined $token;
    if (%params) {
      require URI;
      my $uri = URI->new($url);
      my %query = $uri->query_form;
      $uri->query_form( %query, %params );
      $url = $uri->as_string;
    }

    my $req = $self->generate_http_request(
      GET => $url,
      sub { $self->_parse_list_response(shift) },
    );
    my $http_res = $self->user_agent->request($req);
    my ( $items, $next ) = $req->response_call->($http_res);
    push @all, @$items;
    $token = $next;

    # If the caller constrained to one page, stop after the first response.
    last if defined $opts{page_token} || defined $opts{page_size};
  } while ( defined $token && length $token );

  return @all;
}

sub list_cached_contents {
  my ( $self, %opts ) = @_;
  return [ $self->list_cached_contents_f(%opts)->get ];
}

=method update_cached_content_f

    await $engine->update_cached_content_f( 'cachedContents/abc123', ttl => '600s' );
    await $engine->update_cached_content_f( 'cachedContents/abc123', expire_time => '2030-01-01T00:00:00Z' );

Updates a cache. Per the REST contract, only C<expiration> is updatable
(L<https://ai.google.dev/api/caching#method:-cachedcontents.patch>). Pass
exactly one of C<ttl> or C<expire_time>. The server requires the
C<updateMask> query parameter so we set it explicitly to whichever field
the caller is updating.

=cut

async sub update_cached_content_f {
  my ( $self, $name, %opts ) = @_;
  $self->_assert_http_seam;
  $name = $self->_normalize_name($name);

  my $body = {};
  my @mask;
  if ( exists $opts{ttl} ) {
    $body->{ttl}         = delete $opts{ttl};
    push @mask, 'ttl';
  }
  if ( exists $opts{expire_time} ) {
    $body->{expireTime}  = delete $opts{expire_time};
    push @mask, 'expireTime';
  }
  croak "update_cached_content_f requires exactly one of ttl / expire_time (got "
    . scalar(@mask) . ")"
    unless @mask == 1;
  croak "update_cached_content_f: unknown option(s): " . join(', ', sort keys %opts)
    if %opts;

  # updateMask is a closed set of literal field names (ttl / expireTime), so
  # it rides the seam's query list next to the credential — same shape as
  # alt=sse on the streaming endpoint.
  my $url = $self->gemini_url(
    $self->_cached_content_path($name), updateMask => join(',', @mask) );

  my $req = $self->generate_http_request(
    PATCH => $url,
    sub { $self->_parse_cached_content_response(shift) },
    %$body,
  );

  my $http_res = $self->user_agent->request($req);
  return $req->response_call->($http_res);
}

sub update_cached_content {
  my ( $self, $name, %opts ) = @_;
  return $self->update_cached_content_f( $name, %opts )->get;
}

=method delete_cached_content_f

    await $engine->delete_cached_content_f('cachedContents/abc123');

Delete a cache. Returns C<1> on success.

=cut

async sub delete_cached_content_f {
  my ( $self, $name ) = @_;
  $self->_assert_http_seam;
  $name = $self->_normalize_name($name);

  my $url = $self->gemini_url( $self->_cached_content_path($name) );
  my $req = $self->generate_http_request(
    DELETE => $url,
    sub { $self->_parse_delete_response(shift) },
  );

  my $http_res = $self->user_agent->request($req);
  return $req->response_call->($http_res);
}

sub delete_cached_content {
  my ( $self, $name ) = @_;
  return $self->delete_cached_content_f($name)->get;
}

# --- Internal response parsers ---

sub _parse_cached_content_response {
  my ( $self, $http_res ) = @_;
  my $data = $self->parse_response($http_res);
  my $cc = Langertha::CachedContent->from_hash($data);
  croak "Langertha::Role::CachedContent: response had no name; got: " . $self->json->encode($data)
    unless $cc;
  return $cc;
}

sub _parse_list_response {
  my ( $self, $http_res ) = @_;
  my $data = $self->parse_response($http_res);
  my @items = map { Langertha::CachedContent->from_hash($_) } @{ $data->{cachedContents} || [] };
  return ( \@items, $data->{nextPageToken} );
}

sub _parse_delete_response {
  my ( $self, $http_res ) = @_;
  # DELETE returns an empty JSON object on success; we don't need the body.
  $self->parse_response($http_res);
  return 1;
}

=seealso

=over

=item * L<Langertha::CachedContent> - The value object this role round-trips

=item * L<Langertha::Engine::Gemini> - Composes this role on its Gemini engine

=item * L<https://ai.google.dev/api/caching> - Gemini CachedContent REST reference

=back

=cut

1;
