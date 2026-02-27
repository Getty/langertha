package Langertha::Engine::HuggingFace;
# ABSTRACT: HuggingFace Inference Providers API
our $VERSION = '0.302';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAIBase';

with 'Langertha::Role::Tools';

=head1 SYNOPSIS

    use Langertha::Engine::HuggingFace;

    my $hf = Langertha::Engine::HuggingFace->new(
        api_key => $ENV{HF_TOKEN},
        model   => 'Qwen/Qwen2.5-7B-Instruct',
    );

    print $hf->simple_chat('Hello from Perl!');

    # Access many models through one API
    my $llama = Langertha::Engine::HuggingFace->new(
        api_key => $ENV{HF_TOKEN},
        model   => 'meta-llama/Llama-3.3-70B-Instruct',
    );

=head1 DESCRIPTION

Provides access to HuggingFace Inference Providers, a unified API gateway
for open-source models hosted on the HuggingFace Hub. The endpoint at
C<https://router.huggingface.co/v1> is 100% OpenAI-compatible.

Model names use C<org/model> format (e.g., C<Qwen/Qwen2.5-7B-Instruct>,
C<meta-llama/Llama-3.3-70B-Instruct>). No default model is set;
C<model> must be specified explicitly.

Supports chat, streaming, and MCP tool calling. Embeddings and transcription
are not supported.

Get your API token at L<https://huggingface.co/settings/tokens> and set
C<LANGERTHA_HUGGINGFACE_API_KEY> in your environment.

B<THIS API IS WORK IN PROGRESS>

=cut

has '+url' => (
  lazy => 1,
  default => sub { 'https://router.huggingface.co/v1' },
);

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_HUGGINGFACE_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_HUGGINGFACE_API_KEY or api_key set";
}

sub default_model { croak "".(ref $_[0])." requires model to be set" }

sub _build_supported_operations {[qw(
  createChatCompletion
)]}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://huggingface.co/docs/inference-providers/index> - HuggingFace Inference Providers docs

=item * L<https://huggingface.co/models> - Browse available models

=item * L<https://status.huggingface.co/> - HuggingFace service status

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format role

=back

=cut

1;
