package Langertha::Engine::AKIAnthropic;
# ABSTRACT: AKI.IO via Anthropic-compatible API
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::AnthropicBase';

with 'Langertha::Role::StaticModels';

=head1 SYNOPSIS

    use Langertha::Engine::AKIAnthropic;

    my $aki = Langertha::Engine::AKIAnthropic->new(
        api_key => $ENV{LANGERTHA_AKI_API_KEY},
        model   => 'gemma4-26b',
    );

    print $aki->simple_chat('Hello from Perl!');

=head1 DESCRIPTION

Provides access to L<AKI.IO|https://aki.io/> via its Anthropic-compatible
endpoint at C<https://aki.io/anthropic> (the shared
L<Langertha::Engine::AnthropicBase> appends the C</v1/messages> path). AKI.IO
is a European AI model hub based in Germany — all inference runs on EU
infrastructure, fully GDPR-compliant.

This is the third face of the same provider: L<Langertha::Engine::AKI> speaks
the native API, L<Langertha::Engine::AKIOpenAI> the OpenAI-compatible one, and
this class the Anthropic Messages dialect. All three authenticate with the same
AKI.IO key (C<LANGERTHA_AKI_API_KEY>); pick whichever wire format your code
already speaks.

The key is sent as a raw C<x-api-key> header (B<no> C<Bearer> prefix). The
C<anthropic-version> header is accepted but not required by AKI.IO; the base
class sends it anyway.

B<Silent model fallback:> AKI.IO does B<not> error on unknown model IDs —
"Requests to unknown model names will fall back onto the Minimax M2.5 model."
Claude model names and HuggingFace repository IDs are therefore B<not> a
usable shortcut: they are accepted and silently answered by a different model
than you asked for. Always pass an exact AKI.IO model ID (C<list_models>
returns the documented set) and check C<< $response->model >> if it matters
which model replied.

Models documented for this endpoint: C<apertus-chat-70b>, C<gpt-oss-120b>,
C<gemma4-26b>, C<kimi-k2.7-code-1100b>, C<llama3-chat-8b>, C<llama3-chat-70b>,
C<minimax-m2.5-230b>, C<mistral4-119b>, C<qwen3.6-35b>.

B<Tool calling is undocumented on this endpoint.> AKI.IO's Anthropic
compatibility page lists only C<model>, C<messages>, C<max_tokens>,
C<temperature>, C<top_p>, C<top_k>, C<stop_sequences>, C<stream> and C<system>
as request parameters — no C<tools>. This class inherits the native Anthropic
tool wire format from L<Langertha::Engine::AnthropicBase> (tool calling is
documented by AKI.IO only for the OpenAI-compatible endpoint, which
L<Langertha::Engine::AKIOpenAI> serves through
L<Langertha::Role::HermesTools>), so tool calls against C</anthropic> are
unverified — test before relying on them.

Get your API key at L<https://aki.io/> and set C<LANGERTHA_AKI_API_KEY>.

B<THIS API IS WORK IN PROGRESS>

=cut

# AnthropicBase->chat_request appends '/v1/messages' to url; the default must
# therefore stop at '/anthropic' so the composed endpoint is a single
# '/anthropic/v1/messages' (a '/anthropic/v1' default double-stacks to
# '/anthropic/v1/v1/messages' -> HTTP 404). AKI.IO documents the same rule for
# the Anthropic Python SDK: "AKI.IO API internally appends /v1/messages, so we
# recommend using https://aki.io/anthropic for the base_url instead."
has '+url' => (
  lazy => 1,
  default => sub { 'https://aki.io/anthropic' },
);

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_AKI_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_AKI_API_KEY or api_key set";
}

=attr api_key

The AKI.IO API key — the same key the native and OpenAI-compatible AKI.IO
engines use. If not provided, reads from the C<LANGERTHA_AKI_API_KEY>
environment variable. Sent as a raw C<x-api-key> HTTP header (no C<Bearer>
prefix). Required.

=cut

sub default_model { 'llama3-chat-8b' }

=method default_model

Returns C<llama3-chat-8b>, matching the default of the sibling
L<Langertha::Engine::AKIOpenAI>. AKI.IO documents no default of its own for
this endpoint — an unset or unknown model silently resolves to MiniMax M2.5
(see L</DESCRIPTION>), so this class always sends an explicit model.

=cut

sub api_key_env { 'LANGERTHA_AKI_API_KEY' }

# AKI.IO's machine-readable agent config states "default_max_output_tokens":
# 8192, which is below the documented output limit of every listed model. The
# Anthropic dialect requires max_tokens on every request, so this overrides the
# conservative 1024 of Langertha::Role::AnthropicCompatible.
sub default_response_size { 8192 }

# Static list from the model table on
# https://aki.io/docs/compatibility/anthropic-api-compatibility/ — AKI.IO's own
# docs disagree about model discovery (the Anthropic page points at
# /anthropic/v1/models, the agent integration guide says discovery runs through
# the OpenAI-compatible /openai/v1/models), so this engine does not depend on
# either endpoint. Use Langertha::Engine::AKIOpenAI->list_models for a live list.
sub _build_static_models {[
  { id => 'apertus-chat-70b' },
  { id => 'gpt-oss-120b' },
  { id => 'gemma4-26b' },
  { id => 'kimi-k2.7-code-1100b' },
  { id => 'llama3-chat-8b' },
  { id => 'llama3-chat-70b' },
  { id => 'minimax-m2.5-230b' },
  { id => 'mistral4-119b' },
  { id => 'qwen3.6-35b' },
]}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Engine::AKI> - Native AKI.IO API (with top_k, top_p, max_gen_tokens)

=item * L<Langertha::Engine::AKIOpenAI> - AKI.IO via the OpenAI-compatible endpoint

=item * L<Langertha::Engine::AnthropicBase> - Anthropic-compatible base class

=item * L<https://aki.io/docs/compatibility/anthropic-api-compatibility/> - AKI.IO Anthropic API compatibility docs

=back

=cut

1;
