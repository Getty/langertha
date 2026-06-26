package Langertha::Role::Capabilities;
# ABSTRACT: Engine-capability registry derived from composed roles
our $VERSION = '0.503';
use Moose::Role;

=head1 SYNOPSIS

    if ( $engine->supports('tool_choice_named') ) { ... }

    my $caps = $engine->engine_capabilities;
    for my $cap ( sort keys %$caps ) {
        say "$cap" if $caps->{$cap};
    }

    # Engine-level override for a wire reality the role inventory
    # cannot express (e.g. provider only accepts string tool_choice):
    around engine_capabilities => sub {
      my ( $orig, $self, @rest ) = @_;
      my $caps = $self->$orig(@rest);
      delete $caps->{tool_choice_named};
      return $caps;
    };

=head1 DESCRIPTION

Composed by L<Langertha::Role::Chat> (and therefore present on every
engine), this role provides the C<engine_capabilities> method plus the
C<supports> helper. The default implementation derives the flag set
from which capability-bearing roles the engine composes — no per-role
plumbing required, the registry below is the single source of truth.

Engines override (via C<around>) when the wire reality differs from
the role inventory — for example to clear C<tool_choice_named> on a
provider that only accepts string forms of C<tool_choice>.

The mapping from role to flag is intentionally kept inside this one
module so adding a new capability is a single-file change. The role
itself does not need to know about C<engine_capabilities>.

=cut

# Role-name => list of capability flag names that role contributes.
# Plus implicit:
#   chat            -> simple_chat works (Role::Chat is composed)
#   streaming       -> chat_stream_request is wired up (Role::Streaming)
#   tools_native    -> Role::Tools (the named flags below come too)
#   tools_hermes    -> Role::HermesTools
#   ... see %ROLE_TO_CAPS below.
my %ROLE_TO_CAPS = (
  'Langertha::Role::Chat'             => [qw( chat )],
  'Langertha::Role::Streaming'        => [qw( streaming )],
  'Langertha::Role::Tools'            => [qw(
    tools_native tool_choice_auto tool_choice_any tool_choice_none tool_choice_named
  )],
  'Langertha::Role::HermesTools'      => [qw( tools_hermes )],
  'Langertha::Role::ResponseFormat'   => [qw(
    response_format_json_object response_format_json_schema
  )],
  'Langertha::Role::Embedding'        => [qw( embedding )],
  'Langertha::Role::Transcription'    => [qw( transcription )],
  'Langertha::Role::ImageGeneration'  => [qw( image_generation )],
  'Langertha::Role::Temperature'      => [qw( temperature )],
  'Langertha::Role::ReasoningEffort'  => [qw( reasoning_effort )],
  'Langertha::Role::PromptCache'      => [qw( prompt_cache prompt_cache_key )],
  'Langertha::Role::Seed'             => [qw( seed )],
  'Langertha::Role::ContextSize'      => [qw( context_size )],
  'Langertha::Role::ResponseSize'     => [qw( response_size )],
  'Langertha::Role::SystemPrompt'     => [qw( system_prompt )],
  'Langertha::Role::ParallelToolUse'  => [qw( parallel_tool_use )],
);

sub engine_capabilities {
  my ($self) = @_;
  my %caps;
  for my $role ( keys %ROLE_TO_CAPS ) {
    next unless $self->does($role);
    $caps{$_} = 1 for @{ $ROLE_TO_CAPS{$role} };
  }
  return \%caps;
}

=method engine_capabilities

    my $caps = $engine->engine_capabilities;

Returns a HashRef of capability flags. The default scans the composed
role inventory and sets flags from a static role-to-flags map. Override
via C<around> on an engine to remove flags for capabilities the wire
reality cannot deliver, or to add ad-hoc flags an engine wants to
advertise.

A capability flag means B<the wire accepts the field>, not that any given
model will honor it. For example C<reasoning_effort> being true says the
engine's API will accept a reasoning-effort field on the request; whether a
particular model supports reasoning is a separate runtime concern (every
reasoning field 400s on a non-reasoning model). Engines whose wire never
accepts the field clear the flag via C<around engine_capabilities>
(e.g. MiniMax on its OpenAI endpoint, Perplexity).

Prompt caching is request-side-asymmetric, so it gets B<two> flags rather
than one: C<prompt_cache> means the wire accepts an explicit cache-enable
breakpoint (Anthropic's C<cache_control>), while C<prompt_cache_key> means the
wire accepts an OpenAI-style routing hint (caching itself is automatic there).
The single C<Langertha::Role::PromptCache> role contributes both; the
C<OpenAIBase> / C<AnthropicBase> base classes each clear the one that does not
apply to their wire, so the OpenAI family advertises only the key and the
Anthropic family only the enable breakpoint.

=cut

sub supports {
  my ( $self, $cap ) = @_;
  return !!$self->engine_capabilities->{$cap};
}

=method supports

    if ( $engine->supports('tool_choice_named') ) { ... }

Convenience wrapper that returns a true value when the named capability
is present and truthy in C<engine_capabilities>.

=cut

1;
