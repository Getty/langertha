package Langertha::Usage;
# ABSTRACT: Immutable value object for LLM token usage with cross-provider conversion
our $VERSION = '0.503';
use Moose;
use Scalar::Util qw( blessed );
use Hash::Util::FieldHash qw( fieldhash );

# The %{} overload (back-compat for `$response->usage->{...}`) hijacks every
# `$self->{attr}` deref on the object — including the ones Moose's generated
# accessors use internally. A naive overload therefore breaks the accessors
# (verified: infinite recursion / undef reads). The canonical Perl solution is
# to keep the attribute values in a field hash (keyed by object identity, not
# by the object's own hash) and route both the accessors and the overload
# through it. See "HASH OVERLOAD" below.
fieldhash my %DATA;

use overload
  '%{}' => sub { $_[0]->_as_hash },
  fallback => 1;

has input_tokens  => ( is => 'ro', isa => 'Int', default => 0 );
has output_tokens => ( is => 'ro', isa => 'Int', default => 0 );
has total_tokens  => ( is => 'ro', isa => 'Int', lazy => 1, builder => '_build_total_tokens' );

has raw => (
  is => 'ro',
  isa => 'Maybe[HashRef]',
  default => undef,
);

# The generated accessors read $self->{attr}, which the %{} overload would
# route through _as_hash. Route them through the field hash instead.
around input_tokens  => sub { my ( $orig, $self ) = @_; $DATA{$self}{input_tokens} };
around output_tokens => sub { my ( $orig, $self ) = @_; $DATA{$self}{output_tokens} };
around total_tokens  => sub {
  my ( $orig, $self ) = @_;
  my $d = $DATA{$self} || {};
  return $d->{total_tokens} if defined $d->{total_tokens};
  return ( $d->{input_tokens} // 0 ) + ( $d->{output_tokens} // 0 );
};
around raw => sub { my ( $orig, $self ) = @_; $DATA{$self}{raw} };

# The constructor's writes to $self->{attr} go through the overload and are
# lost, so the field hash is populated here from the raw constructor args.
sub BUILD {
  my ( $self, $args ) = @_;
  $DATA{$self} = {
    input_tokens  => $args->{input_tokens} // 0,
    output_tokens => $args->{output_tokens} // 0,
    total_tokens  => $args->{total_tokens},
    raw           => $args->{raw},
  };
}

sub _build_total_tokens {
  my ($self) = @_;
  return $self->input_tokens + $self->output_tokens;
}

# Build a Usage from any of the wire-format hashrefs we know about.
sub from_hash {
  my ($class, $hash) = @_;
  return $class->new unless $hash && ref($hash) eq 'HASH';

  my $input  = $hash->{input_tokens};
  my $output = $hash->{output_tokens};
  my $total  = $hash->{total_tokens};

  $input  = $hash->{prompt_tokens}     if !defined $input  && defined $hash->{prompt_tokens};
  $input  = $hash->{prompt_eval_count} if !defined $input  && defined $hash->{prompt_eval_count};

  $output = $hash->{completion_tokens} if !defined $output && defined $hash->{completion_tokens};
  $output = $hash->{eval_count}        if !defined $output && defined $hash->{eval_count};

  $input  = 0 + ($input  // 0);
  $output = 0 + ($output // 0);

  my %args = ( input_tokens => $input, output_tokens => $output );
  $args{total_tokens} = 0 + $total if defined $total;
  $args{raw} = $hash;
  return $class->new(%args);
}

# Build a Usage from any response shape: a Langertha::Response, a HashRef
# with a usage key, or undef.
sub from_response {
  my ($class, $response) = @_;
  return $class->new unless $response;

  if ( blessed($response) && $response->isa('Langertha::Response') ) {
    my $usage = $response->has_usage ? $response->usage : undef;
    return $usage if blessed($usage) && $usage->isa('Langertha::Usage');
    return $class->from_hash( $usage || {} );
  }
  if ( ref($response) eq 'HASH' ) {
    return $class->from_hash( $response->{usage} || {} );
  }
  return $class->new;
}

# Immutable merge — returns a new Usage that is the sum of self + other.
sub merge {
  my ($self, $other) = @_;
  return $self unless $other;
  return ref($self)->new(
    input_tokens  => $self->input_tokens  + $other->input_tokens,
    output_tokens => $self->output_tokens + $other->output_tokens,
  );
}

# Canonical hash representation (input_tokens / output_tokens / total_tokens).
sub to_hash {
  my ($self) = @_;
  return {
    input_tokens  => $self->input_tokens,
    output_tokens => $self->output_tokens,
    total_tokens  => $self->total_tokens,
  };
}

# Backing for the %{} overload. When a provider hash was captured (raw), that
# hash is returned verbatim so existing `$response->usage->{...}` callers keep
# seeing the exact engine-normalized keys they always saw — including
# provider-specific extras (cache tokens, token details) and the deliberate
# absence of keys the engine normalized away. Without a raw hash (a Usage
# constructed directly), the canonical to_hash shape is returned.
sub _as_hash {
  my ($self) = @_;
  my $d = $DATA{$self} || {};
  return $d->{raw} if $d->{raw};
  return {
    input_tokens  => $d->{input_tokens} // 0,
    output_tokens => $d->{output_tokens} // 0,
    total_tokens  => $d->{total_tokens} // ( ( $d->{input_tokens} // 0 ) + ( $d->{output_tokens} // 0 ) ),
  };
}

# Make the object transparent to any JSON encoder configured with
# convert_blessed => 1 (the house default, see Langertha::Plugin::Langfuse).
# to_hash is the complete canonical representation, so this is a plain
# delegator — nothing is dropped.
sub TO_JSON { shift->to_hash }

sub to_openai_format {
  my ($self) = @_;
  return {
    prompt_tokens     => $self->input_tokens,
    completion_tokens => $self->output_tokens,
    total_tokens      => $self->total_tokens,
  };
}

sub to_anthropic_format {
  my ($self) = @_;
  return {
    input_tokens  => $self->input_tokens,
    output_tokens => $self->output_tokens,
  };
}

sub to_ollama_format {
  my ($self) = @_;
  return {
    prompt_eval_count => $self->input_tokens,
    eval_count        => $self->output_tokens,
  };
}

=head1 HASH OVERLOAD — backward compatibility

C<Langertha::Usage> overloads C<%{}>, so a Usage object can keep being
dereferenced as a hash: C<< $response->usage->{prompt_tokens} >> keeps working.
This is the deliberate back-compat seam for the coercion of
L<Langertha::Response/usage> from a raw HashRef to a C<Langertha::Usage>
object (karr #43).

When the object was built from a provider hash (via L</from_hash>, which is
what L<Langertha::Response> does in C<BUILDARGS>), the overload returns that
hash B<verbatim> — stored in L</raw>. Callers therefore keep seeing exactly
the engine-normalized keys they always saw: provider-specific extras
(Anthropic cache tokens, OpenAI C<prompt_tokens_details> /
C<completion_tokens_details>) survive, and keys the engine normalized away
(Gemini camelCase, Ollama C<prompt_eval_count> / C<eval_count>) stay absent.
C<exists> checks behave exactly as they did on the raw hash.

For a Usage constructed directly (no raw hash), the overload returns the
canonical L</to_hash> shape (C<input_tokens> / C<output_tokens> /
C<total_tokens>). New code should prefer the accessors and the
C<to_*_format> methods over hash dereferencing.

=head2 Why the field hash

A naive C<%{}> overload on a Moose class is impossible: the overload hijacks
every C<< $self->{attr} >> deref on the object, including the ones Moose's
generated accessors use internally, so the accessors read through the overload
and recurse (verified: infinite recursion / undef reads). The canonical Perl
solution is to keep the attribute values in a C<Hash::Util::FieldHash> keyed
by object identity and route B<both> the accessors (via C<around> modifiers)
and the overload through it. The object's own hash is then never read, so the
overload only ever serves caller hash derefs.

=attr raw

The provider-verbatim hash the object was built from, when it was built via
L</from_hash>. C<undef> for directly constructed objects. Read-only; the
canonical L</to_hash> and C<TO_JSON> deliberately do B<not> include it — it
exists solely to back the C<%{}> overload.

=cut

__PACKAGE__->meta->make_immutable;
1;
