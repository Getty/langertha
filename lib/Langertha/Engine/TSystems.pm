package Langertha::Engine::TSystems;
# ABSTRACT: T-Systems AI Foundation Services (LLM Hub)
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAIBase';

with 'Langertha::Role::Embedding', 'Langertha::Role::Tools';

=head1 SYNOPSIS

    use Langertha::Engine::TSystems;

    my $tsi = Langertha::Engine::TSystems->new(
        api_key => $ENV{LANGERTHA_TSYSTEMS_API_KEY},
        model   => 'gpt-oss-120b',
    );

    print $tsi->simple_chat('Hello from AIFS!');

    my $vector = $tsi->simple_embedding('embed me');

=head1 DESCRIPTION

Provides access to T-Systems' B<AI Foundation Services> (formerly LLM Hub),
an OpenAI-compatible aggregator hosted in Germany / the EU. Composes
L<Langertha::Role::OpenAICompatible> with the AIFS endpoint
(C<https://llm-server.llmhub.t-systems.net/v2>) and Bearer auth.

T-Systems AIFS exposes 30+ open-source and proprietary models behind a single
OpenAI-compatible API. Models hosted on B<T-Cloud> are processed exclusively
in Germany (Llama 3.3, Qwen3-Next 80B, Mistral Small 4, C<gpt-oss-120b>,
Gemma 4, plus the C<BGE-M3> / C<text-embedding-bge-m3> and Jina embeddings);
EU-hosted hyperscaler models are processed within the EU and now include
current frontier models — GPT-5.2 / GPT-5, Claude Sonnet 4.6 / Haiku 4.5, and
Gemini 3 Pro / Flash. This makes AIFS a sovereign-EU route to otherwise non-EU
frontier models. GDPR-compliant.

Get a trial API key at L<https://apikey.llmhub.t-systems.net/> and set
C<LANGERTHA_TSYSTEMS_API_KEY> in your environment.

B<THIS API IS WORK IN PROGRESS>

=cut

has '+url' => (
  lazy => 1,
  default => sub { 'https://llm-server.llmhub.t-systems.net/v2' },
);

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_TSYSTEMS_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_TSYSTEMS_API_KEY or api_key set";
}

sub default_model { 'gpt-oss-120b' }

sub default_embedding_model { 'text-embedding-bge-m3' }

sub _build_supported_operations {[qw(
  createChatCompletion
  createEmbedding
)]}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://docs.llmhub.t-systems.net/> - Official AIFS / LLM Hub documentation

=item * L<https://apikey.llmhub.t-systems.net/> - Trial API key request

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format role

=item * L<Langertha::Engine::AKIOpenAI> - Another EU/Germany OpenAI-compatible engine

=back

=cut

1;
