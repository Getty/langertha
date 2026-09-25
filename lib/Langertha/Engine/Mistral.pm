package Langertha::Engine::Mistral;
# ABSTRACT: Mistral API
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );
use File::ShareDir::ProjectDistDir qw( :all );
use Module::Runtime qw( use_module );

extends 'Langertha::Engine::OpenAIBase';

with map { 'Langertha::Role::'.$_ } qw(
  Embedding
  Tools
);

=head1 SYNOPSIS

    use Langertha::Engine::Mistral;

    my $mistral = Langertha::Engine::Mistral->new(
        api_key      => $ENV{MISTRAL_API_KEY},
        model        => 'mistral-large-latest',
        system_prompt => 'You are a helpful assistant',
        temperature  => 0.5,
    );

    print $mistral->simple_chat('Say something nice');

    my $vector = $mistral->simple_embedding($content);
    # async: await $mistral->simple_embedding_f($content)

=head1 DESCRIPTION

Provides access to Mistral AI's models via their API. Composes
L<Langertha::Role::OpenAICompatible> with Mistral's endpoint
(C<https://api.mistral.ai>) and its OpenAPI spec.

Popular models: C<mistral-small-latest> (default, fast), C<mistral-large-latest>
(most capable, 675B parameters), C<codestral-latest> (code generation),
C<devstral-latest> (development workflows), C<pixtral-large-latest> (vision).
Supports chat, embeddings (default embedding model C<mistral-embed>), and
tool calling; transcription is not available.

Dynamic model listing via C<list_models()>. Get your API key at
L<https://docs.mistral.ai/getting-started/quickstart/> and set
C<LANGERTHA_MISTRAL_API_KEY>.

B<THIS API IS WORK IN PROGRESS>

=cut

has '+url' => (
  lazy => 1,
  default => sub { 'https://api.mistral.ai' },
);

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_MISTRAL_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_MISTRAL_API_KEY or api_key set";
}

sub openapi_file { yaml => dist_file('Langertha','mistral.yaml') };

sub _build_openapi_operations {
  return use_module('Langertha::Spec::Mistral')->data;
}

sub default_model { 'mistral-small-latest' }

# image_input (k266, ADR 0019 k266 Update): Mistral serves text-only and vision
# models side by side (llm-advisor, docs only, 2026-09-25), so the catch-all
# first row clears the flag and the vision models re-assert it: the
# small/medium/large -latest aliases, Pixtral, Small >= 3.1 (2503 on, Small 4 =
# 2603), Medium 3.x (2505 on), Large 3 (2512 on) and Ministral 3 (2512 on).
# Codestral, Nemo, Large 2407/2411, Ministral 2410 and Small 2409/2501 are
# text-only and fall to the catch-all. Confirmed against the model cards
# (llm-advisor, docs only, read 2026-09-25; the vision guide itself is stale):
# mistral-small-latest -> mistral-small-2603 (Small 4, text+image); Medium 3.5
# = mistral-medium-3-5 / mistral-medium-3 / mistral-medium-latest (no dated
# id on the card); Large 3 = mistral-large-2512 / mistral-large-latest;
# Ministral 3 = ministral-{3,8,14}b-2512 / ministral-{3,8,14}b-latest. The
# retired Pixtral, Small 2503/2506 and Medium 2505/2508 rows stay (harmless).
sub model_capability_corrections {
  return (
    qr/\A/                                              => { image_input => 0 },
    qr/\Amistral-(?:small|medium|large)-latest\z/       => { image_input => 1 },
    qr/\Apixtral-/                                      => { image_input => 1 },
    qr/\Amistral-small-(?:250[3-9]|251\d|2[6-9]\d\d)/   => { image_input => 1 },
    qr/\Amistral-medium-(?:250[5-9]|251\d|2[6-9]\d\d)/  => { image_input => 1 },
    qr/\Amistral-large-(?:251[2-9]|2[6-9]\d\d)/         => { image_input => 1 },
    qr/\Aministral-\d+b-(?:251[2-9]|2[6-9]\d\d)/        => { image_input => 1 },
    qr/\Amistral-medium-3(?:-5)?\z/                     => { image_input => 1 },
    qr/\Aministral-\d+b-latest\z/                       => { image_input => 1 },
  );
}

sub chat_operation_id { 'chat_completion_v1_chat_completions_post' }

sub list_models_path { '/v1/models' }

# The static table above is the answer until the caller probes: /v1/models
# states capabilities.vision per model and alias, and a probed fact wins over
# the table for the models it describes (ADR 0032).
sub model_metadata_format { 'mistral' }
sub model_metadata_url    { $_[0]->url . $_[0]->list_models_path }

sub embedding_operation_id { 'embeddings_v1_embeddings_post' }

# Mistral's embedding model; the OpenAI role's text-embedding-3-large is not
# served here (k291).
sub default_embedding_model { 'mistral-embed' }

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://status.mistral.ai/> - Mistral service status

=item * L<https://mistral.ai/models> - Official Mistral models documentation

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format role

=item * L<Langertha::Engine::DeepSeek> - Another OpenAI-compatible engine

=back

=cut

1;
