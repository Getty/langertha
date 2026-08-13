package Langertha::Response;
# ABSTRACT: LLM response with metadata
our $VERSION = '0.503';
use Moose;
use Langertha::ToolCall;
use Langertha::Usage;

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

=head2 TO_JSON — the canonical, bounded representation

C<Langertha::Response> carries a C<TO_JSON> (delegating to L</to_hash>) so
that every L<JSON::MaybeXS> backend encodes a bare Response identically when
C<convert_blessed> is enabled. Decided in karr #50, after karr #43 fixed the
permanent shape of the class (L</usage> is now a L<Langertha::Usage> object
with its own C<TO_JSON>).

The shape is deliberately bounded: L</content> plus the metadata fields that
are present (L</id>, L</model>, L</finish_reason>, L</usage>, L</timing>,
L</created>, L</thinking>, L</rate_limit>, L</tool_calls>). L</raw> and
L</probes> are B<not> included — L</raw> is the entire provider payload
(duplicating every other field, including the echoed prompt) and L</probes>
can hold megabytes of tensor data. A C<TO_JSON> that kept them would blow up
every trace it touched; one that dropped them keeps the object's JSON form
useful without silently discarding the fields a consumer is likely to want.

The string overload is unchanged: C<"$response"> still returns
L</content>, and the C<TO_JSON> does not replace it.

=for stopwords Cpanel

B<Backend uniformity is the point.> Before this method existed, what an
encoder with C<convert_blessed> did with a bare Response depended on the
L<JSON::MaybeXS> backend: L<Cpanel::JSON::XS> fell back to the C<"">
overload and emitted the content string, while L<JSON::XS> and L<JSON::PP>
threw. Consumers on Cpanel silently got C<{"response":"hello"}>, consumers
on JSON::XS/JSON::PP got an exception — the same application behaved
differently on two machines. With C<TO_JSON> all three emit the canonical
hash. The Cpanel behavior was never a contract (it is gone now); callers
that want the content string should stringify explicitly.

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
  isa => 'Maybe[Langertha::Usage]',
  predicate => 'has_usage',
);

=attr usage

Token usage as a L<Langertha::Usage> object. For backward compatibility
C<BUILDARGS> upgrades a plain HashRef (the raw provider usage block) into a
C<Langertha::Usage> automatically; new code can construct the object
directly. The object overloads C<%{}>, so existing callers that dereference
C<< $response->usage->{prompt_tokens} >> keep working — the overload returns
the provider-verbatim hash (see L<Langertha::Usage/"HASH OVERLOAD">).

=cut

has timing => (
  is => 'ro',
  isa => 'Maybe[HashRef]',
  predicate => 'has_timing',
);

=attr timing

Timing information as a HashRef. Holds client-measured
C<ttft_seconds> and C<total_seconds> (Float, seconds) on every engine,
plus provider-native stage durations that engines may populate
engine-specifically — e.g. Ollama's C<total_seconds>, C<load_seconds>,
C<prompt_eval_seconds>, C<eval_seconds> (all Float, seconds), with its
original C<*_duration> keys in nanoseconds preserved for backward
compatibility. See L</ttft_seconds> and L</total_seconds> for the
standard accessors.

=for stopwords first-write-wins

B<Merge policy: first-write-wins.> When both a provider-supplied duration
(e.g. Ollama's C<total_seconds> derived from C<total_duration>) and a
client-measured duration (Langertha::Role::Chat wrapper) are available
for the same key, the provider value wins. See
L<Langertha::Role::Chat/_merge_timing_field> and ADR 0011 in
F<docs/adr/0011-response-timing-seam.md> for the rationale — server-side
duration excludes network jitter and is the better signal for
model-latency observability. Callers that need the client wall-clock
(RTT, queue, TLS handshake, network back) should read
C<$response-E<gt>timing> directly: client-measured deltas are not
written under C<ttft_seconds> / C<total_seconds> when the provider
already populated those keys, but L<Langertha::Role::Chat> does not
delete other timing entries on conflict.

=cut

sub has_ttft {
  my ($self) = @_;
  my $t = $self->timing or return 0;
  return exists $t->{ttft_seconds} && defined $t->{ttft_seconds} ? 1 : 0;
}

sub ttft_seconds {
  my ($self) = @_;
  my $t = $self->timing or return undef;
  return $t->{ttft_seconds};
}

sub has_total {
  my ($self) = @_;
  my $t = $self->timing or return 0;
  return exists $t->{total_seconds} && defined $t->{total_seconds} ? 1 : 0;
}

sub total_seconds {
  my ($self) = @_;
  my $t = $self->timing or return undef;
  return $t->{total_seconds};
}

=method ttft_seconds

    my $ttft = $response->ttft_seconds;     # Float, undef when unmeasured
    if ($response->has_ttft) { ... }

Returns time-to-first-token in seconds (Float), measured client-side
between request send and the first streamed chunk. C<undef> for sync
(non-streaming) calls and for engines that did not record the metric.
Use C<has_ttft> to test availability without warnings.

=cut

=method total_seconds

    my $total = $response->total_seconds;   # Float, undef when unmeasured
    if ($response->has_total) { ... }

Returns end-to-end request time in seconds (Float). On engines that
populate the field from a provider-native metric (currently Ollama,
from C<total_duration>), this is the B<server-reported> duration —
time the model actually spent generating, excluding network jitter.
On engines where only the client wrapper measured, it is the
B<wall-clock> duration from before C<user_agent-E<gt>request> (sync) or
C<do_request> (async) to after the response body was fully consumed.

=for stopwords RTT

The two are not interchangeable: server-time answers "how fast is the
model", wall-clock answers "how long did my call take end-to-end".
Callers that need the wall-clock RTT should read C<$response-E<gt>timing>
directly (the client wrapper writes its measurement under a sibling key
when the provider has not claimed C<total_seconds>; when both are
present the provider value wins — see L</timing>).

C<undef> when the engine did not record the metric. Use C<has_total>
to test availability without warnings.

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

has tool_calls => (
  is        => 'ro',
  isa       => 'Maybe[ArrayRef[Langertha::ToolCall]]',
  predicate => 'has_tool_calls',
);

has probes => (
  is        => 'ro',
  isa       => 'Maybe[HashRef]',
  predicate => 'has_probes',
);

around BUILDARGS => sub {
  my ( $orig, $class, @args ) = @_;
  my $params = $class->$orig(@args);

  # Accept legacy ArrayRef[HashRef] input by upgrading to ToolCall objects.
  if ( ref( $params->{tool_calls} ) eq 'ARRAY' ) {
    $params->{tool_calls} = [
      map {
        ref($_) && eval { $_->isa('Langertha::ToolCall') }
          ? $_
          : Langertha::ToolCall->new(
              name      => ( $_->{name} // '' ),
              arguments => ( ref( $_->{arguments} ) eq 'HASH' ? $_->{arguments} : {} ),
              id        => ( $_->{id} // '' ),
              synthetic => ( $_->{synthetic} ? 1 : 0 ),
            );
      } @{ $params->{tool_calls} }
    ];
  }

  # Accept legacy HashRef usage input by upgrading to a Usage object.
  if ( defined $params->{usage} ) {
    $params->{usage} = ( ref( $params->{usage} ) && eval { $params->{usage}->isa('Langertha::Usage') } )
      ? $params->{usage}
      : Langertha::Usage->from_hash( $params->{usage} );
  }
  return $params;
};

=attr tool_calls

ArrayRef of L<Langertha::ToolCall> objects extracted from the
response, when the engine produced any. Single source of truth for
"what tool calls did the model emit" — both native provider tool
calling and synthesized fallbacks (forced-name via response_format)
land here in the same shape.

For backward compatibility C<BUILDARGS> upgrades plain HashRefs
(C<{ name =E<gt> ..., arguments =E<gt> ..., id =E<gt> ..., synthetic =E<gt> ... }>)
into L<Langertha::ToolCall> objects automatically; new code should
construct the objects directly.

=cut

=method tool_call

    my $tc = $response->tool_call;          # first tool call
    my $tc = $response->tool_call($name);   # named lookup

Returns the L<Langertha::ToolCall> for the first tool call (or the
first matching C<$name>), or C<undef> when no tool calls were
produced.

=cut

sub tool_call {
  my ( $self, $name ) = @_;
  my $tcs = $self->tool_calls or return undef;
  return undef unless @$tcs;
  return $tcs->[0] unless defined $name;
  for my $tc (@$tcs) {
    return $tc if $tc->name eq $name;
  }
  return undef;
}

=method tool_call_args

    my $args = $response->tool_call_args;            # first tool call
    my $args = $response->tool_call_args($name);     # named lookup

Returns the C<arguments> HashRef of the first tool call, or of the
first tool call matching C<$name>. Returns C<undef> when no tool
calls were produced.

=cut

sub tool_call_args {
  my ( $self, $name ) = @_;
  my $tc = $self->tool_call($name) or return undef;
  return $tc->arguments;
}

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

=attr probes

Provider-specific probe data returned by L<Langertha::Engine::VLLMHook> when a
vLLM-Hook server captures attention or hidden-state tensors for a request. A
HashRef keyed by probe cache name (e.g. C<qk_cache>, C<hs_cache>) — each cache
holding serialized tensors as nested JSON lists, plus an optional C<config>
block of scalar metadata. C<undef> for every other engine. Survives
L</clone_with> so it is preserved through C<E<lt>thinkE<gt>> tag filtering.

=cut

sub clone_with {
  my ( $self, %overrides ) = @_;
  my %args = ( content => $self->content );
  for my $attr ( $self->meta->get_all_attributes ) {
    next unless $attr->has_predicate;
    next unless $attr->get_read_method;
    next if $attr->is_required;
    my $name = $attr->name;
    next if $name eq 'content';
    next if exists $overrides{$name};
    $args{$name} = $self->$name if $self->${\"has_$name"};
  }
  return ( ref $self )->new( %args, %overrides );
}

=method clone_with

    my $new = $response->clone_with(content => $filtered, thinking => $thought);

Returns a new Response with the same attributes as the original, except for
the overrides provided. Used by L<Langertha::Role::ThinkTag> to produce a
filtered response while preserving metadata.

Every read-only attribute with a C<has_*> predicate is automatically carried
forward — the implementation iterates the Moose metaclass rather than
maintaining a hand-rolled list, so new attributes added to
L<Langertha::Response> are picked up without further changes here. Required
attributes (currently just C<content>) are handled explicitly above the
loop. Attributes whose names appear in C<%overrides> are skipped during the
copy so the override value is what reaches C<new>.

=cut

=method to_hash

    my $hash = $response->to_hash;

Returns the canonical, bounded HashRef representation of the response:
C<content> plus every metadata field that is present (L</id>, L</model>,
L</finish_reason>, L</usage>, L</timing>, L</created>, L</thinking>,
L</rate_limit>, L</tool_calls>). L</raw> and L</probes> are deliberately
excluded — see L</"TO_JSON — the canonical, bounded representation">.

=cut

sub to_hash {
  my ($self) = @_;
  return {
    content => $self->content,
    ( $self->has_id            ? ( id            => $self->id )            : () ),
    ( $self->has_model         ? ( model         => $self->model )         : () ),
    ( $self->has_finish_reason ? ( finish_reason => $self->finish_reason ) : () ),
    ( $self->has_usage         ? ( usage         => $self->usage )         : () ),
    ( $self->has_timing        ? ( timing        => $self->timing )        : () ),
    ( $self->has_created       ? ( created       => $self->created )       : () ),
    ( $self->has_thinking      ? ( thinking      => $self->thinking )      : () ),
    ( $self->has_rate_limit    ? ( rate_limit    => $self->rate_limit )    : () ),
    ( $self->has_tool_calls    ? ( tool_calls    => $self->tool_calls )    : () ),
  };
}

sub TO_JSON { shift->to_hash }

sub prompt_tokens {
  my ( $self ) = @_;
  my $u = $self->usage or return undef;
  return $u->input_tokens;
}

=method prompt_tokens

Returns the number of prompt/input tokens. Reads the normalized
C<input_tokens> attribute of the L<Langertha::Usage> object (which
L<Langertha::Usage/from_hash> maps from C<prompt_tokens>,
C<input_tokens>, or C<prompt_eval_count>).

=cut

sub completion_tokens {
  my ( $self ) = @_;
  my $u = $self->usage or return undef;
  return $u->output_tokens;
}

=method completion_tokens

Returns the number of completion/output tokens. Reads the normalized
C<output_tokens> attribute of the L<Langertha::Usage> object (which
L<Langertha::Usage/from_hash> maps from C<completion_tokens>,
C<output_tokens>, or C<eval_count>).

=cut

sub total_tokens {
  my ( $self ) = @_;
  my $u = $self->usage or return undef;
  return $u->total_tokens;
}

=method total_tokens

Returns the total token count. Reads the C<total_tokens> attribute of the
L<Langertha::Usage> object — the provider-supplied value when present,
otherwise the sum of prompt and completion tokens (lazy builder).

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
