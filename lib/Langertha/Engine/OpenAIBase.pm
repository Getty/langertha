package Langertha::Engine::OpenAIBase;
# ABSTRACT: Base class for OpenAI-compatible engines
our $VERSION = '0.203';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::Remote';

with 'Langertha::Role::'.$_ for (qw(
  OpenAICompatible
  OpenAPI
  Models
  Temperature
  ResponseSize
  SystemPrompt
  Streaming
  Chat
));

sub default_model { croak "".(ref $_[0])." requires model to be set" }

__PACKAGE__->meta->make_immutable;

1;
