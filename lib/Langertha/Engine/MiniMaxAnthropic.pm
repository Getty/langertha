package Langertha::Engine::MiniMaxAnthropic;
# ABSTRACT: MiniMax API via Anthropic-compatible endpoint (legacy)
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::AnthropicBase';

with 'Langertha::Role::StaticModels';

=head1 SYNOPSIS

    use Langertha::Engine::MiniMaxAnthropic;

    my $minimax = Langertha::Engine::MiniMaxAnthropic->new(
        api_key => $ENV{MINIMAX_API_KEY},
        model   => 'MiniMax-M3',
    );

    print $minimax->simple_chat('Hello from Perl!');

=head1 DESCRIPTION

Provides access to L<MiniMax|https://www.minimax.io/> models via their
Anthropic-compatible endpoint at C<https://api.minimax.io/anthropic> (the
shared L<Langertha::Engine::AnthropicBase> appends the C</v1/messages> path).

B<Historical note:> Until version 0.402 this was the default behavior of
L<Langertha::Engine::MiniMax>. MiniMax's C</anthropic> endpoint is a shim
over their native OpenAI-compatible API — it does not always re-parse
stringified tool-call arguments, which causes intermittent tool-calling
failures where the Anthropic SDK sees a wrapper object whose key rotates
between C<result>, C<arguments>, and the tool name. For new code prefer
L<Langertha::Engine::MiniMax>, which talks to MiniMax's native OpenAI
endpoint and avoids the shim. This class is retained for anyone who needs
the Anthropic wire format specifically.

See L<Langertha::Engine::MiniMax> for the available models list.

Get your API key at L<https://platform.minimax.io/> and set
C<LANGERTHA_MINIMAX_API_KEY> in your environment.

=cut

# AnthropicBase->chat_request appends '/v1/messages' to url; the default must
# therefore stop at '/anthropic' so the composed endpoint is a single
# '/anthropic/v1/messages' (a '/anthropic/v1' default double-stacks to
# '/anthropic/v1/v1/messages' -> HTTP 404 on every model).
has '+url' => (
  lazy => 1,
  default => sub { 'https://api.minimax.io/anthropic' },
);

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_MINIMAX_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_MINIMAX_API_KEY or api_key set";
}

sub default_model { 'MiniMax-M3' }

sub default_response_size { 4096 }

sub _build_static_models {[
  { id => 'MiniMax-M3' },
  { id => 'MiniMax-M2.7' },
  { id => 'MiniMax-M2.5' },
  { id => 'MiniMax-M2.5-highspeed' },
  { id => 'MiniMax-M2.1' },
  { id => 'MiniMax-M2.1-highspeed' },
  { id => 'MiniMax-M2' },
]}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Engine::MiniMax> - Recommended MiniMax engine (OpenAI-compatible endpoint)

=item * L<https://platform.minimax.io/docs/api-reference/text-anthropic-api> - MiniMax Anthropic API docs

=item * L<Langertha::Engine::AnthropicBase> - Anthropic-compatible base class

=back

=cut

1;
