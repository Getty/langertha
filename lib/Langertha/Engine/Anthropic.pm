package Langertha::Engine::Anthropic;
# ABSTRACT: Anthropic API
our $VERSION = '0.305';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::AnthropicBase';

=head1 SYNOPSIS

    use Langertha::Engine::Anthropic;

    my $claude = Langertha::Engine::Anthropic->new(
        api_key => $ENV{ANTHROPIC_API_KEY},
        model   => 'claude-sonnet-4-6',
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

sub default_model { 'claude-sonnet-4-6' }

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Engine::AnthropicBase> - Shared Anthropic-compatible implementation

=item * L<Langertha::Engine::MiniMax> - Anthropic-compatible MiniMax engine

=item * L<Langertha::Engine::LMStudioAnthropic> - Anthropic-compatible LM Studio engine

=back

=cut

1;
