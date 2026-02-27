package Langertha::Role::ImageGeneration;
# ABSTRACT: Role for engines that support image generation
our $VERSION = '0.303';
use Moose::Role;
use Carp qw( croak );

=head1 DESCRIPTION

Engines that can generate images consume this role. It requires
C<image_request> and C<simple_image> methods, and provides an
C<image_model> attribute.

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

=seealso

=over

=item * L<Langertha::ImageGen> - Wrapper class for image generation with plugin support

=item * L<Langertha::Role::Models> - Model selection role

=item * L<Langertha::Plugin::Langfuse> - Observability plugin (hooks into image gen)

=back

=cut

1;
