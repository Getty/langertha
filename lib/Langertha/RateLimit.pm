package Langertha::RateLimit;
# ABSTRACT: Rate limit information from API response headers
our $VERSION = '0.302';
use Moose;

=head1 SYNOPSIS

    my $response = $engine->simple_chat('Hello');

    if ($response->has_rate_limit) {
        my $rl = $response->rate_limit;
        say "Requests remaining: ", $rl->requests_remaining // 'unknown';
        say "Tokens remaining: ", $rl->tokens_remaining // 'unknown';
        say "Reset in: ", $rl->requests_reset // 'unknown', " seconds";
    }

    # Access raw provider-specific headers
    my $raw = $response->rate_limit->raw;

    # Also available on the engine (always reflects latest response)
    if ($engine->has_rate_limit) {
        say "Engine requests remaining: ", $engine->rate_limit->requests_remaining;
    }

=head1 DESCRIPTION

Normalized rate limit data extracted from HTTP response headers. Different
providers use different header naming conventions; this class provides a
unified interface.

B<Supported providers:>

=over 4

=item * OpenAI, Groq, Cerebras, OpenRouter, Replicate, HuggingFace (C<x-ratelimit-*>)

=item * Anthropic (C<anthropic-ratelimit-*>)

=back

Engines that do not return rate limit headers (DeepSeek, Ollama, vLLM,
LlamaCpp, etc.) will not have a rate_limit set.

=cut

has requests_limit => (
  is => 'ro',
  isa => 'Maybe[Num]',
  default => undef,
);

=attr requests_limit

Maximum number of requests allowed in the current window.

=cut

has requests_remaining => (
  is => 'ro',
  isa => 'Maybe[Num]',
  default => undef,
);

=attr requests_remaining

Number of requests remaining in the current window.

=cut

has requests_reset => (
  is => 'ro',
  isa => 'Maybe[Str]',
  default => undef,
);

=attr requests_reset

Time until the request limit resets. Format varies by provider (seconds,
RFC 3339 timestamp, or epoch).

=cut

has tokens_limit => (
  is => 'ro',
  isa => 'Maybe[Num]',
  default => undef,
);

=attr tokens_limit

Maximum number of tokens allowed in the current window.

=cut

has tokens_remaining => (
  is => 'ro',
  isa => 'Maybe[Num]',
  default => undef,
);

=attr tokens_remaining

Number of tokens remaining in the current window.

=cut

has tokens_reset => (
  is => 'ro',
  isa => 'Maybe[Str]',
  default => undef,
);

=attr tokens_reset

Time until the token limit resets. Format varies by provider.

=cut

has raw => (
  is => 'ro',
  isa => 'HashRef',
  default => sub { {} },
);

=attr raw

HashRef of all rate-limit-related headers as returned by the provider.
Useful for accessing provider-specific fields not covered by the
normalized attributes (e.g. Anthropic's C<input-tokens-limit>).

=cut

sub to_hash {
  my ( $self ) = @_;
  return {
    ( defined $self->requests_limit     ? ( requests_limit     => $self->requests_limit )     : () ),
    ( defined $self->requests_remaining ? ( requests_remaining => $self->requests_remaining ) : () ),
    ( defined $self->requests_reset     ? ( requests_reset     => $self->requests_reset )     : () ),
    ( defined $self->tokens_limit       ? ( tokens_limit       => $self->tokens_limit )       : () ),
    ( defined $self->tokens_remaining   ? ( tokens_remaining   => $self->tokens_remaining )   : () ),
    ( defined $self->tokens_reset       ? ( tokens_reset       => $self->tokens_reset )       : () ),
    raw => $self->raw,
  };
}

=method to_hash

    my $hash = $rate_limit->to_hash;

Returns a flat HashRef of all defined rate limit fields plus the raw headers.

=cut

=seealso

=over

=item * L<Langertha::Response> - Response objects carry rate limit data

=item * L<Langertha::Role::HTTP> - Extracts rate limit headers during response parsing

=item * L<Langertha::Engine::Remote> - Stores the latest rate limit on the engine

=back

=cut

__PACKAGE__->meta->make_immutable;

1;
