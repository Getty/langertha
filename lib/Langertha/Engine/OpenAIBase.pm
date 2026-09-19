package Langertha::Engine::OpenAIBase;
# ABSTRACT: Base class for OpenAI-compatible engines
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );
use Module::Runtime qw( use_module );

extends 'Langertha::Engine::Remote';

with map { 'Langertha::Role::'.$_ } qw(
  OpenAICompatible
  OpenAPI
  Models
  Temperature
  ReasoningEffort
  PromptCache
  ResponseSize
  SystemPrompt
  ResponseFormat
  Streaming
  Chat
);

sub _build_openapi_operations {
  return use_module('Langertha::Spec::OpenAI')->data;
}

# The OpenAI family caches automatically — there is no request-side enable
# breakpoint, only the prompt_cache_key routing hint. Clear the Anthropic-style
# enable flag here so the whole family advertises only the key (ADR 0002).
# Partner direction: Langertha::Engine::AnthropicBase runs the symmetric
# correction and deletes prompt_cache_key, keeping prompt_cache. The pair is
# canon in L<ADR 0015|docs/adr/0015-role-composition-patterns.md>.
around engine_capabilities => sub {
  my ( $orig, $self, @rest ) = @_;
  my $caps = $self->$orig(@rest);
  delete $caps->{prompt_cache};
  return $caps;
};

=head1 SYNOPSIS

    package My::CompatibleEngine;
    use Moose;

    extends 'Langertha::Engine::OpenAIBase';

    has '+url' => ( default => 'https://api.example.com/v1' );

    sub _build_api_key {
        return $ENV{MY_API_KEY} || die "MY_API_KEY required";
    }

    sub default_model { 'my-model-v1' }

    __PACKAGE__->meta->make_immutable;

=head1 DESCRIPTION

Intermediate base class for all engines that speak the OpenAI
C</chat/completions> API format. Extends L<Langertha::Engine::Remote> and
composes the full set of OpenAI-compatible roles:
L<Langertha::Role::OpenAICompatible>, L<Langertha::Role::OpenAPI>,
L<Langertha::Role::Models>, L<Langertha::Role::Temperature>,
L<Langertha::Role::ResponseSize>, L<Langertha::Role::SystemPrompt>,
L<Langertha::Role::Streaming>, and L<Langertha::Role::Chat>.

Subclasses must override C<default_model> to return their default model name.
They also typically override C<_build_api_key> to read from an environment
variable, and C<has '+url'> to supply a default API endpoint.

Concrete engines that extend this class:

=over 4

=item * Cloud providers — L<Langertha::Engine::OpenAI>, L<Langertha::Engine::DeepSeek>,
L<Langertha::Engine::Groq>, L<Langertha::Engine::Hetzner>,
L<Langertha::Engine::MiniMax>, L<Langertha::Engine::Mistral>,
L<Langertha::Engine::Moonshot>, L<Langertha::Engine::XAI>,
L<Langertha::Engine::Cerebras>, L<Langertha::Engine::NousResearch>,
L<Langertha::Engine::OpenRouter>, L<Langertha::Engine::Replicate>,
L<Langertha::Engine::HuggingFace>, L<Langertha::Engine::Perplexity>,
L<Langertha::Engine::AKIOpenAI>, L<Langertha::Engine::TSystems>,
L<Langertha::Engine::Scaleway>

=item * Self-hosted — L<Langertha::Engine::OllamaOpenAI>,
L<Langertha::Engine::vLLM>, L<Langertha::Engine::SGLang>,
L<Langertha::Engine::LlamaCpp>, L<Langertha::Engine::LMStudioOpenAI>

=back

For transcription-only engines (Whisper-style) see
L<Langertha::Engine::TranscriptionBase>; that base does I<not>
compose Chat/Tools/Embedding/ImageGeneration so callers get a focused
audio-transcription handle.

=cut

# karr #148: gpt-oss-120b (and similar constrained-decoding stacks) cannot
# combine tool use with a *structured* json_schema response_format in one
# request — the grammar-constrained decoder and the tool-call grammar are
# mutually exclusive, so the provider answers an opaque HTTP 400. This is a
# property of the MODEL, not the endpoint: it fires wherever gpt-oss is served
# — the Cerebras direct route, the TSystems / AKIOpenAI defaults, and aggregator
# routes (OpenRouter / HuggingFace / Replicate) that resolve to a `.../gpt-oss-`
# backend id. Declared here on the shared OpenAI base so every OpenAI-dialect
# engine inherits it, keyed on the model via a regex so a sibling model on the
# same engine is unaffected and a provider that relaxes it per-model
# self-corrects. The seam and the (matcher => rule) contract live in
# Langertha::Role::Chat::model_capability_exclusions. json_object mode is NOT
# constrained decoding and is left to the stricter per-engine rules that need it
# (Cerebras and Groq both refuse json_object alongside tools too, via their own
# all-models overrides).
sub model_capability_exclusions {
  return (
    qr/gpt-oss/ => \&_exclude_tools_with_json_schema,
  );
}

sub _exclude_tools_with_json_schema {
  my ( $self, %request ) = @_;
  my $rf   = $request{response_format};
  my $type = ( ref $rf eq 'HASH' ) ? ( $rf->{type} // '' ) : '';
  return unless $request{has_tools} && $type eq 'json_schema';
  croak "".(ref $self)." cannot combine tools and a json_schema response_format "
    ."for model '".$self->chat_model."': this model rejects structured-output "
    ."constrained decoding together with tool use (the provider answers HTTP "
    ."400). Send tools or a json_schema response_format, not both (run the tools "
    ."first, then a second structured-output turn).";
}

sub default_model { croak "".(ref $_[0])." requires model to be set" }

=method default_model

Abstract. Subclasses must override this to return the default model name
string. The base implementation croaks with a descriptive error message.

    sub default_model { 'gpt-4o-mini' }

=cut

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Engine::Remote> - Parent base class

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format (chat, embeddings, tools, streaming)

=item * L<Langertha::Role::Chat> - C<simple_chat>, C<simple_chat_f>, streaming methods

=item * L<Langertha::Role::Models> - C<model>, C<models>, C<list_models>

=item * L<Langertha::Role::Temperature> - C<temperature> attribute

=item * L<Langertha::Role::ResponseSize> - C<response_size> / C<max_tokens>

=item * L<Langertha::Role::SystemPrompt> - C<system_prompt> attribute

=item * L<Langertha::Role::Streaming> - SSE stream parsing

=item * L<Langertha::Engine::OpenAI> - Canonical OpenAI engine

=item * L<Langertha::Engine::Groq> - Groq ultra-fast inference

=item * L<Langertha::Engine::DeepSeek> - DeepSeek reasoning models

=item * L<Langertha::Engine::OllamaOpenAI> - Ollama OpenAI-compatible endpoint

=item * L<Langertha::Engine::vLLM> - vLLM high-throughput inference server

=item * L<Langertha::Engine::SGLang> - SGLang OpenAI-compatible endpoint

=back

=cut

1;
