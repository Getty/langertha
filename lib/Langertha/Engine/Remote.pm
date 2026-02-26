package Langertha::Engine::Remote;
# ABSTRACT: Base class for all remote engines
our $VERSION = '0.301';
use Moose;

with 'Langertha::Role::'.$_ for (qw(
  JSON
  HTTP
  PluginHost
));

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

=back

=cut

1;
