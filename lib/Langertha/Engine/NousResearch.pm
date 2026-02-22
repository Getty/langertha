package Langertha::Engine::NousResearch;
# ABSTRACT: Nous Research Inference API
our $VERSION = '0.101';
use Moose;
extends 'Langertha::Engine::OpenAI';
use Carp qw( croak );

sub _build_supported_operations {[qw(
  createChatCompletion
)]}

has '+url' => (
  lazy => 1,
  default => sub { 'https://inference-api.nousresearch.com/v1' },
);
around has_url => sub { 1 };

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_NOUSRESEARCH_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_NOUSRESEARCH_API_KEY or api_key set";
}

sub default_model { 'Hermes-3-Llama-3.1-70B' }

# Hermes models use <tool_call> XML tags for tool calling
has '+hermes_tools' => ( default => 1 );

sub embedding_request {
  croak "".(ref $_[0])." doesn't support embedding";
}

sub transcription_request {
  croak "".(ref $_[0])." doesn't support transcription";
}

__PACKAGE__->meta->make_immutable;

=head1 SYNOPSIS

  use Langertha::Engine::NousResearch;

  my $nous = Langertha::Engine::NousResearch->new(
    api_key => $ENV{NOUSRESEARCH_API_KEY},
    model   => 'Hermes-3-Llama-3.1-70B',
  );

  print $nous->simple_chat('Explain the Hermes prompt format');

=head1 DESCRIPTION

This module provides access to Nous Research's inference API. Nous Research
develops open-source language models with a focus on function calling,
structured output, and agentic capabilities.

B<Available Models:>

=over 4

=item * B<Hermes-3-Llama-3.1-70B> - Hermes 3 based on Llama 3.1 70B (default)

=item * B<Hermes-3-Llama-3.1-405B> - Hermes 3 based on Llama 3.1 405B

=item * B<Hermes-4-70B> - Latest Hermes 4 generation, 70B parameters

=item * B<Hermes-4-405B> - Latest Hermes 4 generation, 405B parameters

=item * B<DeepHermes-3-Mistral-24B-Preview> - DeepHermes 3 based on Mistral 24B

=back

B<THIS API IS WORK IN PROGRESS>

=head1 MCP TOOL CALLING

Hermes models support tool calling natively via XML tags in their output.
This engine has C<hermes_tools> enabled by default, which automatically
injects tool descriptions into the system prompt and parses
C<E<lt>tool_callE<gt>> tags from the model's response. No server-side
tool calling support is required.

  use IO::Async::Loop;
  use Net::Async::MCP;
  use Future::AsyncAwait;

  my $loop = IO::Async::Loop->new;
  my $mcp = Net::Async::MCP->new(server => $my_mcp_server);
  $loop->add($mcp);
  await $mcp->initialize;

  my $nous = Langertha::Engine::NousResearch->new(
    api_key     => $ENV{NOUSRESEARCH_API_KEY},
    model       => 'Hermes-3-Llama-3.1-70B',
    mcp_servers => [$mcp],
  );

  my $response = await $nous->chat_with_tools_f('Add 7 and 15');

The instruction text, XML tag names, and full prompt template are
all customizable:

  my $nous = Langertha::Engine::NousResearch->new(
    api_key                  => $ENV{NOUSRESEARCH_API_KEY},
    hermes_tool_instructions => 'You are a helpful assistant.',
    hermes_call_tag          => 'function_call',
    mcp_servers              => [$mcp],
  );

See L<Langertha::Role::Tools/HERMES TOOL CALLING> for details.

=head1 GETTING AN API KEY

L<https://portal.nousresearch.com/>

Set the environment variable:

  export NOUSRESEARCH_API_KEY=your-key-here
  # Or use LANGERTHA_NOUSRESEARCH_API_KEY

=head1 SEE ALSO

=over 4

=item * L<https://nousresearch.com/> - Nous Research homepage

=item * L<https://portal.nousresearch.com/api-docs> - API documentation

=item * L<Langertha::Role::Tools> - Tool calling with Hermes support

=item * L<Langertha::Engine::OpenAI> - Parent class

=item * L<Langertha> - Main Langertha documentation

=back

=cut
