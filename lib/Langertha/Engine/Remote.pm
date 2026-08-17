package Langertha::Engine::Remote;
# ABSTRACT: Base class for all remote engines
our $VERSION = '0.503';
use Moose;

use Langertha::RateLimit;

with map { 'Langertha::Role::'.$_ } qw(
  JSON
  HTTP
  PluginHost
);

=head1 SYNOPSIS

    package My::Engine;
    use Moose;

    extends 'Langertha::Engine::Remote';

    has '+url' => ( default => 'https://api.example.com' );

    sub default_model { 'my-model' }

=head1 DESCRIPTION

Root base class for all HTTP-based LLM engines in Langertha. Composes
L<Langertha::Role::JSON>, L<Langertha::Role::HTTP>, and
L<Langertha::Role::PluginHost>, and makes the C<url> attribute required.

All engines in the distribution extend this class, either directly
(L<Langertha::Engine::Anthropic>, L<Langertha::Engine::Gemini>,
L<Langertha::Engine::Ollama>, L<Langertha::Engine::AKI>) or via the
OpenAI-compatible intermediate class L<Langertha::Engine::OpenAIBase>.

=cut

has '+url' => (
  required => 1,
);

sub api_key_env {
  my ( $class ) = @_;
  (my $name = $class) =~ s/^Langertha::Engine:://;
  return 'LANGERTHA_'.uc($name).'_API_KEY';
}

=method api_key_env

    my $env = $class->api_key_env;

Class method returning the name of the environment variable this engine
reads its API key from (C<LANGERTHA_*_API_KEY>), or C<undef> if the engine
reads none at all. Derived from the class name by default; engines that
share a vendor key override it (e.g. L<Langertha::Engine::AKIOpenAI> reads
C<LANGERTHA_AKI_API_KEY>).

The name alone does not say whether the key is mandatory - pair it with
L</api_key_required>.

=cut

sub api_key_required {
  my ( $class ) = @_;
  return defined $class->api_key_env ? 1 : 0;
}

=method api_key_required

    my $needs_key = $class->api_key_required;

Class method returning true if the engine is unusable without credentials.
Together with L</api_key_env> it covers the three states an engine can be
in:

=over

=item * B<required> - C<api_key_env> names a variable and C<api_key_required>
is true. Cloud providers; building the engine without the key croaks.

=item * B<optional> - C<api_key_env> names a variable and C<api_key_required>
is false. Local-first engines that also serve an authenticated deployment
(L<Langertha::Engine::Ollama> reaching Ollama Cloud,
L<Langertha::Engine::LMStudio> reaching a secured LM Studio): the variable
unlocks that deployment, the engine works without it.

=item * B<none> - C<api_key_env> is C<undef> and C<api_key_required> is
false. The engine reads no environment variable at all
(L<Langertha::Engine::vLLM>, L<Langertha::Engine::SGLang>,
L<Langertha::Engine::LlamaCpp>, L<Langertha::Engine::Whisper>); pass
C<api_key> explicitly when the server was started with one.

=back

Derived from L</api_key_env> by default, so only engines with an optional
key override it.

=cut

has _last_rate_limit => (
  is => 'rw',
  isa => 'Maybe[Langertha::RateLimit]',
  predicate => '_has_last_rate_limit',
  clearer => '_clear_last_rate_limit',
  init_arg => undef,
);

sub rate_limit {
  my ( $self ) = @_;
  return $self->_last_rate_limit;
}

=method rate_limit

    my $rl = $engine->rate_limit;

Returns the L<Langertha::RateLimit> from the most recent API response,
or C<undef> if no rate limit headers were present.

=cut

sub has_rate_limit {
  my ( $self ) = @_;
  return defined $self->_last_rate_limit;
}

=method has_rate_limit

    if ($engine->has_rate_limit) { ... }

Returns true if the engine has rate limit data from the most recent response.

=cut

sub _update_rate_limit {
  my ( $self, $http_response ) = @_;
  my $rl = $self->_parse_rate_limit_headers($http_response);
  if ($rl) {
    $self->_last_rate_limit($rl);
  }
}

sub _parse_rate_limit_headers {
  return undef;
}

# Wire-agnostic generation-parameter block shared by every chat dialect
# (OpenAI, Anthropic, ...). Extracts the can-guarded sibling calls for
# reasoning_kwargs_for / prompt_cache_kwargs_for; the dialect-specific
# fields (response_format on OpenAI, inference_geo on Anthropic, ...) stay
# inline because their placement in the request body depends on dialect
# conventions. Temperature also stays inline: OpenAI emits seed between
# temperature and reasoning, so folding temperature in here would shift
# seed and break the byte order of the OpenAI body (karr #98, ADR 0015
# Decision 3). The helper name is deliberately not knobs_kwargs_for -
# that name belongs to Langertha::Role::RuntimeKnobs for the self-hosted
# prefix-cache knobs (ADR 0012).
sub generation_kwargs_for {
  my ( $self, %controls ) = @_;
  return (
    ( $self->can('reasoning_kwargs_for')    ? $self->reasoning_kwargs_for(%controls)    : () ),
    ( $self->can('prompt_cache_kwargs_for') ? $self->prompt_cache_kwargs_for(%controls) : () ),
  );
}

=method generation_kwargs_for

    my @kwargs = $engine->generation_kwargs_for(%$controls);

Emits the wire-agnostic generation-parameter kwargs that every chat dialect
shares - the C<reasoning_kwargs_for> and C<prompt_cache_kwargs_for> outputs,
each gated by C<can()> so engines without those roles stay quiet. C<%controls>
is the per-request controls hash from C<chat_f> (karr #46), passed wholesale;
keys it does not carry fall back to the engine attributes inside the
underlying L<Langertha::Role::ReasoningEffort/reasoning_kwargs_for> and
L<Langertha::Role::PromptCache/prompt_cache_kwargs_for>. Returned as a list
suitable for spreading into a request body. Dialect-specific emission
(C<temperature>, C<response_format>, C<seed>, C<knobs_kwargs_for>,
C<inference_geo>, ...) stays at the call site because each dialect positions
those fields at a specific place in the body.

=cut

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Engine::OpenAIBase> - Intermediate base for all OpenAI-compatible engines

=item * L<Langertha::Engine::Anthropic> - Anthropic Claude (extends this directly)

=item * L<Langertha::Engine::Gemini> - Google Gemini (extends this directly)

=item * L<Langertha::Engine::Ollama> - Ollama native API (extends this directly)

=item * L<Langertha::Engine::AKI> - AKI EU engine (extends this directly)

=item * L<Langertha::Role::HTTP> - HTTP transport with C<url>, C<user_agent>, request builders

=item * L<Langertha::Role::JSON> - Shared JSON encoder/decoder

=item * L<Langertha::Role::PluginHost> - Plugin system with lifecycle events

=item * L<Langertha::RateLimit> - Rate limit data stored per-engine

=back

=cut

1;
