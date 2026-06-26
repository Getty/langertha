package Langertha::Engine::MoonshotAnthropic;
# ABSTRACT: Moonshot AI Kimi API via Anthropic-compatible endpoint
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::AnthropicBase';

with 'Langertha::Role::StaticModels';

=head1 SYNOPSIS

    use Langertha::Engine::MoonshotAnthropic;

    my $moonshot = Langertha::Engine::MoonshotAnthropic->new(
        api_key => $ENV{MOONSHOT_API_KEY},
        model   => 'kimi-k2.6',
    );

    print $moonshot->simple_chat('Hello from Perl!');

=head1 DESCRIPTION

Provides access to L<Moonshot AI|https://www.moonshot.ai/>'s Kimi models via
their Anthropic-compatible endpoint at C<https://api.moonshot.ai/anthropic>
(the shared L<Langertha::Engine::AnthropicBase> appends the C</v1/messages>
path). This is the endpoint Moonshot documents for Claude Code / Anthropic-SDK
clients.

For new code prefer L<Langertha::Engine::Moonshot>, which talks to Moonshot's
native OpenAI-compatible endpoint. This class is retained for callers that need
the Anthropic wire format specifically.

See L<Langertha::Engine::Moonshot> for the available models list.

Get your API key at L<https://platform.kimi.ai/> and set
C<LANGERTHA_MOONSHOT_API_KEY> in your environment.

=cut

# AnthropicBase->chat_request appends '/v1/messages' to url; the default must
# therefore stop at '/anthropic' so the composed endpoint is a single
# '/anthropic/v1/messages' (a '/anthropic/v1' default would double-stack to
# '/anthropic/v1/v1/messages' -> HTTP 404).
has '+url' => (
  lazy => 1,
  default => sub { 'https://api.moonshot.ai/anthropic' },
);

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_MOONSHOT_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_MOONSHOT_API_KEY or api_key set";
}

sub default_model { 'kimi-k2.6' }

sub default_response_size { 4096 }

sub _build_static_models {[
  { id => 'kimi-k2.6' },
  { id => 'kimi-k2.7-code' },
  { id => 'kimi-k2.7-code-highspeed' },
  { id => 'kimi-k2.5' },
  { id => 'moonshot-v1-8k' },
  { id => 'moonshot-v1-32k' },
  { id => 'moonshot-v1-128k' },
]}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Engine::Moonshot> - Recommended Moonshot engine (OpenAI-compatible endpoint)

=item * L<https://platform.kimi.ai/docs/api/overview> - Kimi API docs

=item * L<Langertha::Engine::AnthropicBase> - Anthropic-compatible base class

=back

=cut

1;
