package Langertha::Role::CachedContent;
# ABSTRACT: Role for the explicit cachedContent resource lifecycle (create/get/list/update/delete)
our $VERSION = '0.503';
use Moose::Role;
use Future::AsyncAwait;
use Carp qw( croak );
use Langertha::CachedContent;

requires qw(
  url
  api_key
  user_agent
  generate_http_request
  parse_response
  json
);

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

Endpoints:

=over

=item * C<POST   {url}/v1beta/cachedContents>              — create
=item * C<GET    {url}/v1beta/cachedContents>              — list (paginated)
=item * C<GET    {url}/v1beta/cachedContents/{name}>       — get
=item * C<PATCH  {url}/v1beta/cachedContents/{name}>       — update (expiration only)
=item * C<DELETE {url}/v1beta/cachedContents/{name}>       — delete

=back

All methods are async via L<Future::AsyncAwait>. The sync L<Langertha::Role::Chat>
wrappers (L</create_cached_content>, etc.) delegate to the async versions
through the engine's L<IO::Async> loop when one is wired up; otherwise
they run synchronously.

The role owns the URL shape and HTTP plumbing only — it does B<not>
introspect model names or filter by generation. Engines narrow
C<Langertha::Engine::Gemini>'s advertising of the capability per model
family (see L<Langertha::Engine::Gemini>'s C<around engine_capabilities>).

=cut

# Path is the same as the Gemini REST base, sans the trailing model
# segment; cachedContents is its own top-level collection under /v1beta.
sub _cached_contents_url {
  my ( $self ) = @_;
  return $self->url . '/v1beta/cachedContents';
}

sub _cached_content_url {
  my ( $self, $name ) = @_;
  croak "name must look like cachedContents/{id}; got '$name'"
    unless defined $name && $name =~ m{\AcachedContents/[^/\s]+\z};
  return $self->url . '/v1beta/' . $name;
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

Posts to C<POST /v1beta/cachedContents>, parses the response into a
L<Langertha::CachedContent>. Accepts either a pre-built
L<Langertha::CachedContent> (the role will call C<to_create_body> for
you) or the individual named attributes.

Returns the persisted CachedContent.

=cut

async sub create_cached_content_f {
  my ( $self, @args ) = @_;

  my $cc;
  if ( @args == 1 && ref( $args[0] ) && eval { $args[0]->isa('Langertha::CachedContent') } ) {
    $cc = $args[0];
  }
  else {
    $cc = Langertha::CachedContent->new( @args );
  }

  my $url = $self->_cached_contents_url;
  my $body = $cc->to_create_body;

  my $req = $self->generate_http_request(
    POST => $url . '?key=' . $self->api_key,
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
  $name = $self->_normalize_name($name);

  my $url = $self->_cached_content_url($name) . '?key=' . $self->api_key;
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

  my @all;
  my $token = $opts{page_token};
  my $page_size = $opts{page_size};

  do {
    my %query = ( key => $self->api_key );
    $query{pageSize}  = $page_size if defined $page_size;
    $query{pageToken} = $token     if defined $token;

    require URI;
    my $uri = URI->new( $self->_cached_contents_url );
    $uri->query_form(%query);
    my $url = $uri->as_string;

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

  require URI;
  my $uri = URI->new( $self->_cached_content_url($name) );
  $uri->query_form( key => $self->api_key, updateMask => join(',', @mask) );
  my $url = $uri->as_string;

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
  $name = $self->_normalize_name($name);

  my $url = $self->_cached_content_url($name) . '?key=' . $self->api_key;
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
