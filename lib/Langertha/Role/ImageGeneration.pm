package Langertha::Role::ImageGeneration;
# ABSTRACT: Role for engines that support image generation
our $VERSION = '0.503';
use Moose::Role;
use Future::AsyncAwait;
use Carp qw( croak );

# simple_image_f sends through the engine's async backend (k292): injected
# client > Net::Async::HTTP > the sync LWP shim (ADR 0027).
with 'Langertha::Role::AsyncHTTP';

=head1 DESCRIPTION

Engines that can generate images consume this role. It requires
C<image_request> and C<simple_image> methods, and provides an
C<image_model> attribute and the async L</simple_image_f>.

=cut

requires 'image_request';
requires 'simple_image';

has image_model => (
  is => 'ro',
  isa => 'Maybe[Str]',
  lazy_build => 1,
);
sub _build_image_model {
  my ( $self ) = @_;
  croak "".(ref $self)." can't handle models!" unless $self->does('Langertha::Role::Models');
  return $self->default_image_model if $self->can('default_image_model');
  return $self->model;
}

=attr image_model

The model name to use for image generation requests. Lazily defaults to
C<default_image_model> if the engine provides it, otherwise falls back
to the general C<model> attribute from L<Langertha::Role::Models>.

=cut

async sub simple_image_f {
  my ( $self, $prompt, %extra ) = @_;
  my $request = $self->image_request($prompt, %extra);
  my $response = await $self->_async_do_request_f( request => $request );
  return $request->response_call->($response);
}

=method simple_image_f

    my $images = await $engine->simple_image_f('A cat in space', size => '1024x1024');

Async variant of C<simple_image>: same arguments, returns a L<Future> that
resolves to the same value (for the OpenAI dialect an ArrayRef of image
objects, see L<Langertha::Role::OpenAICompatible/image_response>) and fails
with the same error text. The request goes through the engine's async
backend (L<Langertha::Role::AsyncHTTP>), so
L<Langertha::Role::HTTP/user_agent_timeout> bounds it on
L<Net::Async::HTTP> too; without that module it runs synchronously over LWP.

=cut

=seealso

=over

=item * L<Langertha::ImageGen> - Wrapper class for image generation with plugin support

=item * L<Langertha::Role::Models> - Model selection role

=item * L<Langertha::Plugin::Langfuse> - Observability plugin (hooks into image gen)

=back

=cut

1;
