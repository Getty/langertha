package Langertha::Role::Embedding;
# ABSTRACT: Role for APIs with embedding functionality
our $VERSION = '0.503';
use Moose::Role;
use Future::AsyncAwait;
use Carp qw( croak );
use Log::Any qw( $log );

# simple_embedding_f sends through the engine's async backend (k292): injected
# client > Net::Async::HTTP > the sync LWP shim (ADR 0027).
with 'Langertha::Role::AsyncHTTP';

requires qw(
  embedding_request
  embedding_response
);

has embedding_model => (
  is => 'ro',
  isa => 'Maybe[Str]',
  lazy_build => 1,
);
sub _build_embedding_model {
  my ( $self ) = @_;
  croak "".(ref $self)." can't handle models!" unless $self->does('Langertha::Role::Models');
  return $self->model unless $self->can('default_embedding_model');
  my $default = $self->default_embedding_model;
  return $default if defined $default;
  # No fixed embedding model (self-hosted servers, k297): the caller's model,
  # never the engine's own placeholder default_model ('default' 404s on older
  # vLLM); undef leaves the model field out and the server picks.
  my $model = $self->model;
  return undef unless defined $model;
  return undef if $self->can('default_model') && $model eq $self->default_model;
  return $model;
}

=attr embedding_model

The model name to use for embedding requests. Lazily defaults to
C<default_embedding_model> if the engine provides it, otherwise falls back
to the general C<model> attribute from L<Langertha::Role::Models>.

An engine whose C<default_embedding_model> returns C<undef> (the self-hosted
vLLM, LlamaCpp and LM Studio servers) has no fixed embedding model: it uses
the C<model> you set, and without one sends no C<model> field, so the
server embeds with the model it serves.

=cut

has embedding_dimensions => (
  is => 'ro',
  isa => 'Maybe[Int]',
);

=attr embedding_dimensions

Optional size of the returned vectors, for models that can shorten them
(OpenAI C<text-embedding-3-*>, C<gemini-embedding-001>). OpenAI-compatible
engines send it as C<dimensions>, L<Langertha::Engine::Gemini> as
C<embedContentConfig.outputDimensionality>; a matching extra passed to
C<embedding_request> wins over it. Unset (the default), nothing is sent and
the model answers in its native size. Other engines do not send it.

=cut

sub embedding {
  my ( $self, $text ) = @_;
  return $self->embedding_request($text);
}

=method embedding

    my $request = $engine->embedding($text);

Builds and returns an embedding HTTP request object for the given C<$text>.
Use L</simple_embedding> to execute the request and get the result directly.

=cut

sub simple_embedding {
  my ( $self, $text ) = @_;
  $log->debugf("[%s] simple_embedding, model=%s, %s",
    ref $self, $self->embedding_model // 'default',
    ref $text eq 'ARRAY' ? 'inputs='.scalar(@{$text}) : 'input_length='.length($text // ''));
  my $request = $self->embedding($text);
  my $response = $self->user_agent->request($request);
  return $request->response_call->($response);
}

=method simple_embedding

    my $vector  = $engine->simple_embedding($text);
    my $vectors = $engine->simple_embedding([ $text_a, $text_b ]);

Sends an embedding request for C<$text> and returns the embedding vector
(an ArrayRef of floats). An ArrayRef of strings is sent as one batch
request and returns an ArrayRef of vectors, one per input and in input
order. Blocks until the request completes. L</simple_embedding_f> is the
non-blocking variant.

=cut

async sub simple_embedding_f {
  my ( $self, $text ) = @_;
  $log->debugf("[%s] simple_embedding_f, model=%s, %s",
    ref $self, $self->embedding_model // 'default',
    ref $text eq 'ARRAY' ? 'inputs='.scalar(@{$text}) : 'input_length='.length($text // ''));
  my $request = $self->embedding($text);
  my $response = await $self->_async_do_request_f( request => $request );
  return $request->response_call->($response);
}

=method simple_embedding_f

    my $vector  = await $engine->simple_embedding_f($text);
    my $vectors = await $engine->simple_embedding_f([ $text_a, $text_b ]);

Async variant of L</simple_embedding>: returns a L<Future> that resolves to
the same value (a vector, or an ArrayRef of vectors for an ArrayRef input)
and fails with the same error text. The request goes through the engine's
async backend (L<Langertha::Role::AsyncHTTP>), so
L<Langertha::Role::HTTP/user_agent_timeout> bounds it on
L<Net::Async::HTTP> too; without that module it runs synchronously over LWP.

=cut

=seealso

=over

=item * L<Langertha::Role::HTTP> - HTTP transport layer

=item * L<Langertha::Role::Models> - Model selection (provides C<embedding_model>)

=back

=cut

1;
