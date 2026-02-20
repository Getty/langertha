package Langertha::Role::Models;
# ABSTRACT: Role for APIs with several models
our $VERSION = '0.101';
use Moose::Role;

requires qw(
  default_model
);

has models => (
  is => 'rw',
  isa => 'ArrayRef[Str]',
  lazy_build => 1,
);
sub _build_models {
  my ( $self ) = @_;
  # Prefer dynamic list_models() over static all_models()
  return $self->list_models() if $self->can('list_models');
  return [
    $self->can('all_models')
      ? $self->all_models
      : $self->model
  ];
}

has model => (
  is => 'ro',
  isa => 'Str',
  lazy_build => 1,
);
sub _build_model {
  my ( $self ) = @_;
  return $self->default_model;
}

# Cache configuration
has models_cache_ttl => (
  is => 'ro',
  isa => 'Int',
  default => sub { 3600 }, # 1 hour default
);

has _models_cache => (
  is => 'rw',
  isa => 'HashRef',
  default => sub { {} },
  traits => ['Hash'],
  handles => {
    _clear_models_cache => 'clear',
  },
);

# Public method to clear the cache
sub clear_models_cache {
  my ($self) = @_;
  $self->_clear_models_cache;
  return;
}

1;
