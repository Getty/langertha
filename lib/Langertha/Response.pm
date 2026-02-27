package Langertha::Response;
# ABSTRACT: LLM response with metadata
our $VERSION = '0.302';
use Moose;

use overload
  '""' => sub { $_[0]->content },
  fallback => 1;

=head1 SYNOPSIS

    my $response = $engine->simple_chat('Hello');

    # Stringifies to content (backward compatible)
    print $response;
    print "Response: $response\n";

    # Access metadata
    say $response->model;
    say $response->id;
    say $response->finish_reason;

    # Token usage
    say "Prompt tokens: ", $response->prompt_tokens;
    say "Completion tokens: ", $response->completion_tokens;
    say "Total tokens: ", $response->total_tokens;

    # Full raw response
    use Data::Dumper;
    print Dumper($response->raw);

=head1 DESCRIPTION

Wraps LLM response text content together with all available metadata
from the API response. Uses C<overload> for string context so existing
code treating responses as plain strings continues to work.

=cut

has content => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

=attr content

The text content of the response. Required.

=cut

has raw => (
  is => 'ro',
  isa => 'HashRef',
  predicate => 'has_raw',
);

=attr raw

The full parsed API response as a HashRef.

=cut

has id => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_id',
);

=attr id

Provider-specific response ID.

=cut

has model => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_model',
);

=attr model

The actual model used for the response.

=cut

has finish_reason => (
  is => 'ro',
  isa => 'Maybe[Str]',
  predicate => 'has_finish_reason',
);

=attr finish_reason

Why the response ended: C<stop>, C<end_turn>, C<length>, C<tool_calls>, etc.
Provider-specific values are preserved as-is.

=cut

has usage => (
  is => 'ro',
  isa => 'Maybe[HashRef]',
  predicate => 'has_usage',
);

=attr usage

Token usage counts as a HashRef. Keys vary by provider but are normalized
by the convenience methods.

=cut

has timing => (
  is => 'ro',
  isa => 'Maybe[HashRef]',
  predicate => 'has_timing',
);

=attr timing

Timing information as a HashRef. Currently only populated by Ollama.

=cut

has created => (
  is => 'ro',
  isa => 'Maybe[Int]',
  predicate => 'has_created',
);

=attr created

Unix timestamp of when the response was created.

=cut

has thinking => (
  is => 'ro',
  isa => 'Maybe[Str]',
  predicate => 'has_thinking',
);

has rate_limit => (
  is => 'ro',
  isa => 'Maybe[Langertha::RateLimit]',
  predicate => 'has_rate_limit',
);

=attr rate_limit

Optional L<Langertha::RateLimit> object with rate limit information from the
API response headers. Only present when the provider returns rate limit headers.

=cut

=attr thinking

Chain-of-thought reasoning content. Populated automatically from native API
fields (DeepSeek C<reasoning_content>, Anthropic C<thinking> blocks, Gemini
C<thought> parts) or from C<E<lt>thinkE<gt>> tag filtering when
L<Langertha::Role::ThinkTag/think_tag_filter> is enabled.

=cut

sub clone_with {
  my ( $self, %overrides ) = @_;
  my %args = (content => $self->content);
  for my $attr (qw( raw id model finish_reason usage timing created thinking rate_limit )) {
    my $pred = "has_$attr";
    $args{$attr} = $self->$attr if $self->$pred;
  }
  return (ref $self)->new(%args, %overrides);
}

=method clone_with

    my $new = $response->clone_with(content => $filtered, thinking => $thought);

Returns a new Response with the same attributes as the original, except for
the overrides provided. Used by L<Langertha::Role::ThinkTag> to produce a
filtered response while preserving metadata.

=cut

sub prompt_tokens {
  my ( $self ) = @_;
  my $u = $self->usage or return undef;
  return $u->{prompt_tokens} // $u->{input_tokens};
}

=method prompt_tokens

Returns the number of prompt/input tokens. Checks C<prompt_tokens> and
C<input_tokens> keys in usage.

=cut

sub completion_tokens {
  my ( $self ) = @_;
  my $u = $self->usage or return undef;
  return $u->{completion_tokens} // $u->{output_tokens};
}

=method completion_tokens

Returns the number of completion/output tokens. Checks C<completion_tokens>
and C<output_tokens> keys in usage.

=cut

sub total_tokens {
  my ( $self ) = @_;
  my $u = $self->usage or return undef;
  return $u->{total_tokens} if defined $u->{total_tokens};
  my $p = $self->prompt_tokens;
  my $c = $self->completion_tokens;
  return undef unless defined $p && defined $c;
  return $p + $c;
}

=method total_tokens

Returns the total token count. Uses C<total_tokens> from usage if available,
otherwise sums prompt and completion tokens.

=cut

sub requests_remaining {
  my ( $self ) = @_;
  my $rl = $self->rate_limit or return undef;
  return $rl->requests_remaining;
}

=method requests_remaining

Returns the number of requests remaining from rate limit headers, or C<undef>.

=cut

sub tokens_remaining {
  my ( $self ) = @_;
  my $rl = $self->rate_limit or return undef;
  return $rl->tokens_remaining;
}

=method tokens_remaining

Returns the number of tokens remaining from rate limit headers, or C<undef>.

=cut

=seealso

=over

=item * L<Langertha::RateLimit> - Rate limit data from response headers

=item * L<Langertha::Stream::Chunk> - Single chunk from a streaming response

=item * L<Langertha::Role::Chat> - Chat role that produces response objects

=item * L<Langertha::Role::OpenAICompatible> - Parses responses into this class

=back

=cut

__PACKAGE__->meta->make_immutable;

1;
