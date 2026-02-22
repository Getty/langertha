package Langertha::Engine::AKIOpenAI;
# ABSTRACT: AKI.IO via OpenAI-compatible API
our $VERSION = '0.101';
use Moose;
use Carp qw( croak );

with 'Langertha::Role::'.$_ for (qw(
  JSON
  HTTP
  OpenAICompatible
  OpenAPI
  Models
  Temperature
  ResponseSize
  SystemPrompt
  Streaming
  Chat
));

with 'Langertha::Role::Tools';

has '+url' => (
  lazy => 1,
  default => sub { 'https://aki.io/v1' },
);
around has_url => sub { 1 };

sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_AKI_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_AKI_API_KEY or api_key set";
}

sub default_model { 'llama3_8b_chat' }

sub _build_supported_operations {[qw( createChatCompletion )]}

sub embedding_request { croak "".(ref $_[0])." doesn't support embedding" }
sub transcription_request { croak "".(ref $_[0])." doesn't support transcription" }

__PACKAGE__->meta->make_immutable;

=head1 SYNOPSIS

  use Langertha::Engine::AKIOpenAI;

  # Direct construction
  my $aki = Langertha::Engine::AKIOpenAI->new(
    api_key => $ENV{AKI_API_KEY},
    model   => 'llama3_8b_chat',
  );

  print $aki->simple_chat('Hello!');

  # Streaming
  $aki->simple_chat_stream(sub {
    print shift->content;
  }, 'Tell me about Perl');

  # Preferred: create via AKI's openai() method
  use Langertha::Engine::AKI;

  my $aki_native = Langertha::Engine::AKI->new(
    api_key => $ENV{AKI_API_KEY},
    model   => 'llama3_8b_chat',
  );
  my $oai = $aki_native->openai;
  print $oai->simple_chat('Hello via OpenAI format!');

=head1 DESCRIPTION

This engine provides access to AKI.IO's OpenAI-compatible API endpoint
at C<https://aki.io/v1>. It composes L<Langertha::Role::OpenAICompatible>
for the standard OpenAI API format.

B<AKI.IO is a European AI model hub based in Germany.> All inference runs
on EU-based infrastructure, fully compliant with GDPR and European data
protection regulations. No data leaves the EU. This makes AKI.IO an ideal
choice for applications with data sovereignty requirements.

B<Supported features:>

=over 4

=item * Chat completions (with SSE streaming)

=item * MCP tool calling (OpenAI function format)

=item * Temperature and response size control

=item * Dynamic model listing via C<list_models()>

=back

B<Not supported:> Embeddings, transcription. Calling C<embedding_request>
or C<transcription_request> will throw an error. Use L<Langertha::Engine::AKI>
for the native API, or a different engine for embeddings.

For the native AKI.IO API with additional inference parameters (C<top_k>,
C<top_p>, C<max_gen_tokens>), use L<Langertha::Engine::AKI>.

B<THIS API IS WORK IN PROGRESS>

=attr api_key

The AKI.IO API key. If not provided at construction time, reads from
the C<LANGERTHA_AKI_API_KEY> environment variable. Sent as a Bearer
token in the C<Authorization> HTTP header. Required.

=seealso

=over

=item * L<Langertha::Engine::AKI> - Native AKI.IO API (with top_k, top_p, max_gen_tokens)

=item * L<Langertha::Role::OpenAICompatible> - OpenAI API format role

=item * L<https://aki.io/docs> - AKI.IO API documentation

=item * L<Langertha> - Main Langertha documentation

=back

=cut
