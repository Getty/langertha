package Langertha::Engine::Perplexity;
# ABSTRACT: Perplexity Sonar API
our $VERSION = '0.201';
use Moose;
extends 'Langertha::Engine::OpenAI';
use Carp qw( croak );

=head1 SYNOPSIS

    use Langertha::Engine::Perplexity;

    my $perplexity = Langertha::Engine::Perplexity->new(
        api_key => $ENV{PERPLEXITY_API_KEY},
        model   => 'sonar-pro',
    );

    print $perplexity->simple_chat('What are the latest Perl releases?');

    # Streaming
    $perplexity->simple_chat_stream(sub {
        print shift->content;
    }, 'Summarize recent Perl news');

    # Async with Future::AsyncAwait
    use Future::AsyncAwait;
    my $response = await $perplexity->simple_chat_f('What is new in Perl?');

=head1 DESCRIPTION

Provides access to Perplexity's Sonar API. Extends L<Langertha::Engine::OpenAI>
with Perplexity's endpoint (C<https://api.perplexity.ai>). Perplexity models
are search-augmented LLMs with real-time web access; responses include
citations alongside generated text.

Available models: C<sonar> (default, fast), C<sonar-pro> (deeper analysis),
C<sonar-reasoning> (chain-of-thought), C<sonar-reasoning-pro> (most capable).

Limitations: tool calling, embeddings, and transcription are not supported.
Only chat and streaming are available.

Get your API key at L<https://www.perplexity.ai/settings/api> and set
C<LANGERTHA_PERPLEXITY_API_KEY>.

B<THIS API IS WORK IN PROGRESS>

=cut

sub _build_supported_operations {[qw(
  createChatCompletion
)]}

has '+url' => (
  lazy => 1,
  default => sub { 'https://api.perplexity.ai' },
);
around has_url => sub { 1 };

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_PERPLEXITY_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_PERPLEXITY_API_KEY or api_key set";
}

sub default_model { 'sonar' }

sub embedding_request {
  croak "".(ref $_[0])." doesn't support embedding";
}

sub transcription_request {
  croak "".(ref $_[0])." doesn't support transcription";
}

sub chat_with_tools_f {
  croak "".(ref $_[0])." doesn't support tool calling";
}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<https://docs.perplexity.ai/> - Official Perplexity API documentation

=item * L<Langertha::Engine::OpenAI> - Parent class

=item * L<Langertha> - Main Langertha documentation

=back

=cut

1;
