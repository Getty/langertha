package Langertha::Role::UserAgent;
# ABSTRACT: Role for WWW::Chain User Agent

use Moose::Role;
use WWW::Chain::UA::LWP;

has user_agent_timeout => (
  isa => 'Int',
  is => 'ro',
  predicate => 'has_user_agent_timeout',
);

has user_agent_agent => (
  isa => 'Str',
  is => 'ro',
  lazy_build => 1,
);
sub _build_user_agent_agent {
  my ( $self ) = @_;
  return "".(ref $self)."";
}

has user_agent => (
  does => 'WWW::Chain::UA',
  is => 'ro',
  lazy_build => 1,
);
sub _build_user_agent {
  my ( $self ) = @_;
  return WWW::Chain::UA::LWP->new(
    agent => $self->user_agent_agent,
    $self->has_user_agent_timeout ? ( timeout => $self->user_agent_timeout ) : (),
  );
}

1;
