package Langertha::Manifest::Builder;
# ABSTRACT: Build a provider manifest from configured engines (offline, never copies a secret)
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );
use Scalar::Util qw( blessed );
use URI;
use Langertha::Manifest;

=head1 SYNOPSIS

    use Langertha::Manifest::Builder;

    # One engine, one endpoint
    my $manifest = Langertha::Manifest::Builder->from_engine(
      Langertha::Engine::vLLM->new( url => 'http://gpu01:8000/v1', model => 'qwen3' ),
    );
    print $manifest->to_json;

    # A proxy exposing several protocol endpoints under its public URL
    my $builder = Langertha::Manifest::Builder->new(
      provider_id => 'my-knarr',
      issuer      => 'https://knarr.example',
    );
    $builder->add_engine( $openai_engine,
      endpoint_id => 'openai', base_url => 'https://knarr.example/v1',
      models      => [ 'gpt-5.6', 'local-qwen' ] );
    $builder->add_endpoint( id => 'ollama', dialect => 'ollama',
      base_url => 'https://knarr.example' );
    $builder->add_model( id => 'local-qwen', endpoint_ref => 'ollama',
      capabilities => { chat => 1, streaming => 1 } );
    my $manifest = $builder->manifest;

=head1 DESCRIPTION

Maps configured Langertha engines into a L<Langertha::Manifest>. Everything
is read from the engine object: no network I/O happens (in particular
C<list_models> is never called).

=over

=item * B<dialect> — from the engine family, most specific class first:
L<Langertha::Engine::Perplexity> → C<perplexity-agent>,
L<Langertha::Engine::OpenAIResponses> → C<responses>,
L<Langertha::Engine::OpenAIBase> → C<openai-chat>,
L<Langertha::Engine::AnthropicBase> → C<anthropic>,
L<Langertha::Engine::Gemini> → C<gemini>, L<Langertha::Engine::Ollama> →
C<ollama>, L<Langertha::Engine::AKI> → C<aki>, L<Langertha::Engine::LMStudio>
→ C<lmstudio>. A transcription-only engine
(L<Langertha::Engine::TranscriptionBase>) has no chat dialect and croaks.

=item * B<base_url> — the engine's C<url> (override with C<base_url> to
publish a public URL instead of an internal one).

=item * B<auth> — from the engine class's C<api_key_required> /
C<api_key_env>: a required key yields an C<api_key> auth entry; an optional
key only when one is configured; no key, no entry. Only the I<definedness>
of the key is looked at — its value never enters the manifest.

=item * B<capabilities> — C<engine_capabilities> evaluated B<per model>
(the engine is cloned in memory with C<chat_model> set to that model id), so
model-scoped corrections apply. Names are exactly the registry's
(L<Langertha::Role::Capabilities>); the Builder adds none.

=back

=cut

has provider_id => (
  is        => 'ro',
  isa       => 'Str',
  writer    => '_set_provider_id',
  predicate => 'has_provider_id',
);

has issuer => (
  is        => 'ro',
  isa       => 'Str',
  writer    => '_set_issuer',
  predicate => 'has_issuer',
);

has extensions => ( is => 'ro', isa => 'HashRef', default => sub { {} } );

has _endpoints => ( is => 'ro', default => sub { [] } );
has _auth      => ( is => 'ro', default => sub { [] } );
has _models    => ( is => 'ro', default => sub { [] } );

=attr provider_id

The manifest's C<provider_id>. When not given, the first L</add_engine>
derives it from the engine class (C<Langertha::Engine::vLLM> → C<vllm>).

=attr issuer

The manifest's C<issuer>. When not given, the first L</add_engine> derives
it from the origin of the engine's URL.

=attr extensions

HashRef passed through untouched into the manifest's C<extensions>.

=cut

# Most specific first: OpenAIResponses isa OpenAI isa OpenAIBase.
my @DIALECT_BY_CLASS = (
  [ 'Langertha::Engine::Perplexity'        => 'perplexity-agent' ],
  [ 'Langertha::Engine::OpenAIResponses'   => 'responses' ],
  [ 'Langertha::Engine::TranscriptionBase' => undef ],
  [ 'Langertha::Engine::OpenAIBase'        => 'openai-chat' ],
  [ 'Langertha::Engine::AnthropicBase'     => 'anthropic' ],
  [ 'Langertha::Engine::Gemini'            => 'gemini' ],
  [ 'Langertha::Engine::Ollama'            => 'ollama' ],
  [ 'Langertha::Engine::AKI'               => 'aki' ],
  [ 'Langertha::Engine::LMStudio'          => 'lmstudio' ],
);

sub dialect_for_engine {
  my ( $class, $engine ) = @_;
  for my $row (@DIALECT_BY_CLASS) {
    my ( $isa, $dialect ) = @$row;
    next unless $engine->isa($isa);
    return $dialect;
  }
  return undef;
}

=method dialect_for_engine

    my $dialect = Langertha::Manifest::Builder->dialect_for_engine($engine);

The manifest dialect of an engine (see L</DESCRIPTION>), or C<undef> when
the engine has none.

=cut

sub from_engine {
  my ( $class, $engine, %opt ) = @_;
  my $self = $class->new(
    map { exists $opt{$_} ? ( $_ => delete $opt{$_} ) : () } qw( provider_id issuer extensions )
  );
  $self->add_engine( $engine, %opt );
  return $self->manifest;
}

=method from_engine

    my $manifest = Langertha::Manifest::Builder->from_engine( $engine, %options );

Shortcut: a builder with C<provider_id> / C<issuer> / C<extensions> from
C<%options>, one L</add_engine> with the rest, then L</manifest>.

=cut

sub add_engine {
  my ( $self, $engine, %opt ) = @_;
  croak 'Langertha::Manifest::Builder: add_engine needs an engine with engine_capabilities'
    unless blessed($engine) && $engine->can('engine_capabilities');

  my $dialect = $opt{dialect} // $self->dialect_for_engine($engine);
  croak 'Langertha::Manifest::Builder: ' . ref($engine) . ' has no manifest dialect'
    . ' (not a chat engine); pass dialect => ... to name one'
    unless defined $dialect;

  my $base_url = $opt{base_url} // ( $engine->can('url') ? $engine->url : undef );
  croak 'Langertha::Manifest::Builder: ' . ref($engine) . ' has no url; pass base_url => ...'
    unless defined $base_url;

  $self->_set_provider_id( _provider_id_for( ref $engine ) ) unless $self->has_provider_id;
  $self->_set_issuer( _origin_of($base_url) ) unless $self->has_issuer;

  my $auth_ref;
  my $auth_type = $opt{auth} // _auth_type_for($engine);
  if ( $auth_type ne 'none' ) {
    $auth_ref = $opt{auth_id} // 'api';
    my ($existing) = grep { $_->id eq $auth_ref } @{ $self->_auth };
    if ($existing) {
      croak "Langertha::Manifest::Builder: auth id '$auth_ref' already has type '"
        . $existing->type . q{'}
        unless $existing->type eq $auth_type;
    }
    else {
      $self->add_auth( id => $auth_ref, type => $auth_type );
    }
  }

  my $endpoint_id = $opt{endpoint_id} // 'chat';
  $self->add_endpoint(
    id       => $endpoint_id,
    dialect  => $dialect,
    base_url => $base_url,
    ( defined $auth_ref ? ( auth_ref => $auth_ref ) : () ),
  );

  my @models = $opt{models} ? @{ $opt{models} } : ( $engine->chat_model );
  for my $model_id (@models) {
    $self->add_model(
      id           => $model_id,
      endpoint_ref => $endpoint_id,
      capabilities => _capabilities_for( $engine, $model_id ),
    );
  }
  return $self;
}

=method add_engine

    $builder->add_engine( $engine,
      endpoint_id => 'chat',            # default 'chat'
      base_url    => $public_url,       # default $engine->url
      models      => [ ... ],           # default [ $engine->chat_model ]
      auth        => 'api_key',         # or 'none'; default from the engine class
      auth_id     => 'api',             # default 'api' (shared across engines)
      dialect     => 'openai-chat',     # default from the engine family
    );

Adds one endpoint for the engine, its auth entry (if any) and one model
entry per model id. Croaks for an engine without a manifest dialect unless
C<dialect> is given. Returns the builder.

=cut

sub add_endpoint {
  my ( $self, %args ) = @_;
  my $endpoint = Langertha::Manifest::Endpoint->new(%args);
  croak "Langertha::Manifest::Builder: duplicate endpoint id '" . $endpoint->id . q{'}
    if grep { $_->id eq $endpoint->id } @{ $self->_endpoints };
  push @{ $self->_endpoints }, $endpoint;
  return $self;
}

=method add_endpoint

    $builder->add_endpoint( id => ..., dialect => ..., base_url => ..., auth_ref => ... );

Adds an endpoint that is not an engine (a proxy's own protocol route).

=cut

sub add_auth {
  my ( $self, %args ) = @_;
  push @{ $self->_auth }, Langertha::Manifest::Auth->new(%args);
  return $self;
}

=method add_auth

    $builder->add_auth( id => 'api', type => 'api_key' );

Adds an auth entry.

=cut

sub add_model {
  my ( $self, %args ) = @_;
  push @{ $self->_models }, Langertha::Manifest::Model->new(%args);
  return $self;
}

=method add_model

    $builder->add_model( id => ..., endpoint_ref => ..., capabilities => { ... } );

Adds a model entry.

=cut

sub manifest {
  my ($self) = @_;
  croak 'Langertha::Manifest::Builder: no provider_id (add an engine or pass provider_id)'
    unless $self->has_provider_id;
  croak 'Langertha::Manifest::Builder: no issuer (add an engine or pass issuer)'
    unless $self->has_issuer;
  return Langertha::Manifest->new(
    provider_id => $self->provider_id,
    issuer      => $self->issuer,
    endpoints   => [ @{ $self->_endpoints } ],
    auth        => [ @{ $self->_auth } ],
    models      => [ @{ $self->_models } ],
    extensions  => $self->extensions,
  );
}

=method manifest

Returns the validated L<Langertha::Manifest>.

=cut

sub _provider_id_for {
  my ($class_name) = @_;
  ( my $name = $class_name ) =~ s/\A.*::Engine:://;
  $name =~ s/\A.*:://;
  return lc $name;
}

sub _origin_of {
  my ($url) = @_;
  my $uri = URI->new($url);
  return $url unless $uri->can('host') && $uri->can('port');
  my $origin = $uri->scheme . '://' . $uri->host;
  $origin .= ':' . $uri->port if $uri->port != $uri->default_port;
  return $origin;
}

sub _auth_type_for {
  my ($engine) = @_;
  return 'api_key' if $engine->can('api_key_required') && $engine->api_key_required;
  # Optional key: announce the mechanism only when one is configured. Only
  # definedness is inspected; the value is dropped on the spot.
  return 'none'
    unless $engine->can('api_key_env') && defined $engine->api_key_env && $engine->can('api_key');
  my $configured = defined( scalar eval { $engine->api_key } );
  return $configured ? 'api_key' : 'none';
}

sub _capabilities_for {
  my ( $engine, $model_id ) = @_;
  # engine_capabilities is model-scoped (ADR 0019 layer 3 and model-aware
  # `around engine_capabilities`, e.g. Gemini): evaluate it on an in-memory
  # clone whose chat_model is this model. The caller's engine is not touched.
  my $probe = $engine->can('chat_model') && ( $engine->chat_model // '' ) ne $model_id
    ? $engine->meta->clone_object( $engine, chat_model => $model_id )
    : $engine;
  my $caps = $probe->engine_capabilities;
  return { map { $_ => ( $caps->{$_} ? 1 : 0 ) } keys %$caps };
}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Manifest> - The manifest value object and validator

=item * L<Langertha::Role::Capabilities> - Where the capability names come from

=back

=cut

1;
