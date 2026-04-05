package Langertha::Engine::SGLang;
# ABSTRACT: SGLang inference server
our $VERSION = '0.310';
use Moose;

extends 'Langertha::Engine::OpenAIBase';

with 'Langertha::Role::Tools';

=head1 SYNOPSIS

    use Langertha::Engine::SGLang;

    my $sglang = Langertha::Engine::SGLang->new(
        url   => 'http://localhost:30000/v1',
        model => 'Qwen/Qwen2.5-7B-Instruct',
    );

    print $sglang->simple_chat('Say something nice');

=head1 DESCRIPTION

Adapter for SGLang's OpenAI-compatible endpoint.
SGLang is typically exposed as C</v1/chat/completions> with optional
tool-calling support depending on model/backend setup.

Only C<url> is required. Use the full C</v1> base URL.
No API key is required for local setups.

B<THIS API IS WORK IN PROGRESS>

=cut

has '+url' => (
  required => 1,
);

sub default_model { 'default' }

sub _build_supported_operations {[qw(
  createChatCompletion
  createCompletion
)]}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://docs.sglang.ai/> - SGLang documentation

=item * L<Langertha::Engine::OpenAIBase> - Base class for OpenAI-compatible engines

=item * L<Langertha::Role::Tools> - MCP tool calling interface

=item * L<Langertha::Engine::vLLM> - Similar self-hosted OpenAI-compatible engine

=back

=cut

1;
