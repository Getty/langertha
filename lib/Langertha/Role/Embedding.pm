package Langertha::Role::Embedding;
# ABSTRACT: Role for APIs with embedding functionality
our $VERSION = '0.302';
use Moose::Role;
use Carp qw( croak );
use Log::Any qw( $log );

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
  return $self->default_embedding_model if $self->can('default_embedding_model');
  return $self->model;
}

=attr embedding_model

The model name to use for embedding requests. Lazily defaults to
C<default_embedding_model> if the engine provides it, otherwise falls back
to the general C<model> attribute from L<Langertha::Role::Models>.

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
  $log->debugf("[%s] simple_embedding, model=%s, input_length=%d",
    ref $self, $self->embedding_model // 'default', length($text // ''));
  my $request = $self->embedding($text);
  my $response = $self->user_agent->request($request);
  return $request->response_call->($response);
}

=method simple_embedding

    my $vector = $engine->simple_embedding($text);

Sends an embedding request for C<$text> and returns the embedding vector.
Blocks until the request completes.

=cut

=seealso

=over

=item * L<Langertha::Role::HTTP> - HTTP transport layer

=item * L<Langertha::Role::Models> - Model selection (provides C<embedding_model>)

=back

=cut

1;
