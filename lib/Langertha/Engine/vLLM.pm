package Langertha::Engine::vLLM;
# ABSTRACT: vLLM inference server
our $VERSION = '0.101';
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

This module provides access to vLLM, a high-throughput inference engine for
large language models. vLLM serves models via an OpenAI-compatible API, so
this engine inherits all functionality from L<Langertha::Engine::OpenAI>.

B<Features:>

=over 4

=item * OpenAI-compatible chat completions

=item * Streaming support

=item * MCP tool calling (requires server-side configuration)

=back

B<THIS API IS WORK IN PROGRESS>

=head1 MCP TOOL CALLING

vLLM supports tool calling but requires the server to be started with
specific flags:

  vllm serve Qwen/Qwen2.5-3B-Instruct \
    --enable-auto-tool-choice \
    --tool-call-parser hermes

The C<--tool-call-parser> depends on the model. Common parsers:

=over 4

=item * B<hermes> - For Qwen2.5, NousResearch Hermes models

=item * B<llama3> - For Meta Llama 3.x models

=item * B<mistral> - For Mistral models

=item * B<granite> - For IBM Granite models

=back

Once the server is configured, tool calling works like any other engine:

  my $vllm = Langertha::Engine::vLLM->new(
    url         => 'http://localhost:8000/v1',
    model       => 'Qwen/Qwen2.5-3B-Instruct',
    mcp_servers => [$mcp],
  );

  my $response = await $vllm->chat_with_tools_f('Add 7 and 15');

B<Note:> The URL must include the C</v1> path prefix.

=head1 HOW TO INSTALL VLLM

L<https://docs.vllm.ai/en/latest/getting_started/installation.html>

Using Docker:

  docker run --gpus all -p 8000:8000 \
    vllm/vllm-openai \
    --model Qwen/Qwen2.5-3B-Instruct \
    --enable-auto-tool-choice \
    --tool-call-parser hermes

=head1 SEE ALSO

=over 4

=item * L<https://docs.vllm.ai/> - vLLM documentation

=item * L<Langertha::Engine::OpenAI> - Parent engine (OpenAI-compatible API)

=item * L<Langertha::Role::Tools> - Tool calling interface

=item * L<Langertha> - Main Langertha documentation

=back

=cut
