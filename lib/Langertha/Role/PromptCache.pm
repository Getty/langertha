package Langertha::Role::PromptCache;
# ABSTRACT: Role for an engine with a request-side prompt-caching control
our $VERSION = '0.503';
use Moose::Role;
use Langertha::PromptCache;

has prompt_cache => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

=attr prompt_cache

Enable an Anthropic C<cache_control> breakpoint on the request (the top-level
auto-place form). Defaults off. No effect on the OpenAI wire, where caching is
automatic — see L</prompt_cache_key> for the only OpenAI-side lever.

=cut

has prompt_cache_ttl => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_prompt_cache_ttl',
);

=attr prompt_cache_ttl

Optional Anthropic cache time-to-live: C<5m> (the current default when unset)
or C<1h>. Only meaningful together with L</prompt_cache>; the C<1h> window
requires this set explicitly.

=cut

has prompt_cache_key => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_prompt_cache_key',
);

=attr prompt_cache_key

Optional OpenAI C<prompt_cache_key> routing hint. OpenAI prompt caching is
automatic; this only steers which cache shard is used. No effect on the
Anthropic wire.

=cut

has cache_wire_format => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  builder => '_build_cache_wire_format',
);

# Defaults to the OpenAI dialect; AnthropicBase overrides the builder. This role
# is composed only on OpenAIBase and AnthropicBase (the two providers with a
# real request-side knob), so those are the only two formats.
sub _build_cache_wire_format { 'openai' }

=attr cache_wire_format

    cache_wire_format => 'anthropic'

The per-engine enum naming which caching dialect this engine speaks —
C<openai> | C<anthropic>. Drives the value-object dispatch in
L</prompt_cache_kwargs>. The default follows the engine base-class hierarchy:
C<OpenAIBase> leaves it at C<openai>, C<AnthropicBase> overrides to
C<anthropic>.

=cut

sub prompt_cache_kwargs {
  my ( $self ) = @_;
  return Langertha::PromptCache->new(
    enable => $self->prompt_cache,
    ( $self->has_prompt_cache_ttl ? ( ttl => $self->prompt_cache_ttl ) : () ),
    ( $self->has_prompt_cache_key ? ( key => $self->prompt_cache_key ) : () ),
  )->to( $self->cache_wire_format );
}

=method prompt_cache_kwargs

    my %kwargs = $engine->prompt_cache_kwargs;

Returns the body kwargs to merge into a chat request for the configured caching
options, serialized for L</cache_wire_format> via L<Langertha::PromptCache>.
Empty list when nothing applies to the engine's wire (caching off / no key).

=cut

=seealso

=over

=item * L<Langertha::PromptCache> - The value object this role dispatches to

=item * L<Langertha::Role::Capabilities> - Where C<prompt_cache> / C<prompt_cache_key> are registered

=item * L<Langertha::Role::ReasoningEffort> - Sibling request-side reasoning control

=back

=cut

1;
