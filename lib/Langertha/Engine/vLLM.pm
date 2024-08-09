package Langertha::Engine::vLLM;
# ABSTRACT: vLLM inference server

use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAI';

has '+url' => (
  required => 1,
);

sub default_model { croak "".(ref $_[0])." requires a default_model" }

sub _build_api_key { 'vllm' }

sub _build_supported_operations {[qw(
  createChatCompletion
  createCompletion
)]}

1;

=head1 SYNOPSIS

  use Langertha::Engine::vLLM;

  my $vllm = Langertha::Engine::vLLM->new(
    url => $ENV{VLLM_URL},
    model => $ENV{VLLM_MODEL},
    system_prompt => 'You are a helpful assistant',
  );

  print($vllm->simple_chat('Say something nice'));

=head1 DESCRIPTION

B<THIS API IS WORK IN PROGRESS>

=head1 HOW TO INSTALL VLLM

L<https://docs.vllm.ai/en/latest/getting_started/installation.html>

=cut
