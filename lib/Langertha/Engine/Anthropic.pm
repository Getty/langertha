package Langertha::Engine::Anthropic;
# ABSTRACT: Anthropic API
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::AnthropicBase';

=head1 SYNOPSIS

    use Langertha::Engine::Anthropic;

    my $claude = Langertha::Engine::Anthropic->new(
        api_key => $ENV{ANTHROPIC_API_KEY},
        model   => 'claude-sonnet-5',
    );

    print $claude->simple_chat('Generate Perl Moose classes for GeoJSON');

=head1 DESCRIPTION

Concrete Anthropic engine for Claude models. Inherits shared
Anthropic-compatible behavior from L<Langertha::Engine::AnthropicBase> and
provides Anthropic cloud defaults (URL, API key env var, default model).

B<THIS API IS WORK IN PROGRESS>

=cut

has '+url' => (
  lazy => 1,
  default => sub { 'https://api.anthropic.com' },
);

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_ANTHROPIC_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_ANTHROPIC_API_KEY or api_key set";
}

sub default_model { 'claude-sonnet-5' }

# The first-party Claude Messages API has native structured output
# (output_config.format, GA — ADR 0005 amendment), so response_format is emitted
# natively here rather than through the legacy synthesized-tool rewrite that the
# /anthropic shim engines still use.
sub _native_structured_output { 1 }

# Per-model wire corrections (k138 / ADR 0002 amendment). The tool /
# structured-output / sampling wire reality on the Claude API is per-MODEL, not
# per-engine, so it lives here rather than in `around engine_capabilities`.
sub model_capability_corrections {
  return (
    # k135 point 1: temperature / top_p / top_k are deprecated on the Messages
    # API and return a 400 with a non-default value on a GROWING set of models.
    # The ticket named Opus 4.7/4.8; the verified set (Anthropic thinking/effort
    # reference, read 2026-09) is broader — every model below rejects them,
    # while Opus 4.6 / Sonnet 4.6 / Haiku 4.5 and older still accept them.
    # Clearing the capability makes AnthropicCompatible drop temperature from
    # the wire for these models (attribute or per-request alike).
    qr/\Aclaude-opus-4-7/  => { temperature => 0 },
    qr/\Aclaude-opus-4-8/  => { temperature => 0 },
    qr/\Aclaude-opus-5/    => { temperature => 0 },
    qr/\Aclaude-sonnet-5/  => { temperature => 0 },
    qr/\Aclaude-fable-5/   => { temperature => 0 },  # fable-5 and fable-5-1
    qr/\Aclaude-mythos-5/  => { temperature => 0 },  # mythos-5 and mythos-5-1
    # k133 point 2: forced tool use (tool_choice type `any` / `tool`) returns a
    # 400 on Fable 5.1 and Mythos 5.1 only (their 5.0 siblings still allow it).
    # Clearing the forced-tool caps makes chat_f's auto-rewrite (ADR 0005) route
    # a forced named tool through native structured output (output_config.format)
    # instead of emitting a tool_choice the model rejects. tool_choice_auto /
    # tool_choice_none stay — only `any` and `tool` 400.
    qr/\Aclaude-fable-5-1/  => { tool_choice_named => 0, tool_choice_any => 0 },
    qr/\Aclaude-mythos-5-1/ => { tool_choice_named => 0, tool_choice_any => 0 },
  );
}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Engine::AnthropicBase> - Shared Anthropic-compatible implementation

=item * L<Langertha::Engine::MiniMax> - Anthropic-compatible MiniMax engine

=item * L<Langertha::Engine::LMStudioAnthropic> - Anthropic-compatible LM Studio engine

=back

=cut

1;
