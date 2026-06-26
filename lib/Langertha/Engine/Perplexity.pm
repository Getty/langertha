package Langertha::Engine::Perplexity;
# ABSTRACT: Perplexity Sonar API
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::OpenAIBase';

with 'Langertha::Role::StaticModels';

=head1 SYNOPSIS

    use Langertha::Engine::Perplexity;

    my $perplexity = Langertha::Engine::Perplexity->new(
        api_key => $ENV{PERPLEXITY_API_KEY},
        model   => 'sonar-pro',
    );

    print $perplexity->simple_chat('What are the latest Perl releases?');

    # Streaming
    $perplexity->simple_chat_stream(sub {
        print shift->content;
    }, 'Summarize recent Perl news');

    # Async with Future::AsyncAwait
    use Future::AsyncAwait;
    my $response = await $perplexity->simple_chat_f('What is new in Perl?');

=head1 DESCRIPTION

Provides access to Perplexity's Sonar API. Composes
L<Langertha::Role::OpenAICompatible> with Perplexity's endpoint
(C<https://api.perplexity.ai>). Perplexity models are search-augmented
LLMs with real-time web access; responses include citations alongside
generated text.

Available models: C<sonar> (default, fast), C<sonar-pro> (deeper analysis),
C<sonar-reasoning-pro> (chain-of-thought reasoning), C<sonar-deep-research>
(exhaustive multi-step research). The plain C<sonar-reasoning> model has been
deprecated by Perplexity and removed.

Limitations: tool calling, embeddings, and transcription are not supported.
Only chat and streaming are available. Tool calling is intentionally not
composed onto this engine: Perplexity's classic C</chat/completions> Sonar
path rejects a C<tools> array (verified live 2026-06-26: HTTP 400 "Tool
calling is not supported for this model"). Function calling exists only on
Perplexity's separate Agent API (a Responses-style surface), which Langertha
does not yet model.

Get your API key at L<https://www.perplexity.ai/settings/api> and set
C<LANGERTHA_PERPLEXITY_API_KEY>.

B<THIS API IS WORK IN PROGRESS>

=cut

sub _build_supported_operations {[qw(
  createChatCompletion
)]}

has '+url' => (
  lazy => 1,
  default => sub { 'https://api.perplexity.ai' },
);

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_PERPLEXITY_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_PERPLEXITY_API_KEY or api_key set";
}

sub default_model { 'sonar' }

# Current Sonar API lineup (https://docs.perplexity.ai/getting-started/models,
# verified 2026-06-26). sonar-reasoning (non-pro) was dropped — it now 400s
# "model has been deprecated and is no longer available". This engine speaks
# the classic /chat/completions path only; it deliberately does NOT compose
# Langertha::Role::Tools because that path rejects a tools array (see DESCRIPTION).
sub _build_static_models {[
  { id => 'sonar' },
  { id => 'sonar-pro' },
  { id => 'sonar-reasoning-pro' },
  { id => 'sonar-deep-research' },
]}

# The classic Sonar /chat/completions path does not accept reasoning_effort
# (the reasoning models reason on their own, with no request-side knob): clear
# the capability and never emit the field.
around engine_capabilities => sub {
  my ( $orig, $self, @rest ) = @_;
  my $caps = $self->$orig(@rest);
  delete $caps->{reasoning_effort};
  return $caps;
};

sub reasoning_kwargs { () }

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://status.perplexity.com/> - Perplexity service status

=item * L<https://docs.perplexity.ai/> - Official Perplexity API documentation

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format role

=item * L<Langertha::Engine::DeepSeek> - Another search-augmented engine (web-aware reasoning)

=back

=cut

1;
