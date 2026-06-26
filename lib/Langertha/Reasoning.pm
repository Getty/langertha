package Langertha::Reasoning;
# ABSTRACT: Immutable normalized reasoning-effort control with cross-provider conversion
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

=head1 SYNOPSIS

    my $r = Langertha::Reasoning->new(
        effort => 'high',
        model  => 'claude-opus-4-8',
    );
    my %kwargs = $r->to('anthropic');
    # ( output_config => { effort => 'high' }, thinking => { type => 'adaptive' } )

=head1 DESCRIPTION

Canonical value object for the request-side reasoning-effort knob, dispatched
by an engine's C<reasoning_wire_format>. Mirrors L<Langertha::Tool> /
L<Langertha::ToolChoice>: the value-set clamping and per-provider placement of
the field live in this one reviewable place rather than scattered across
engines (ADR 0001).

The normalized vocabulary is the OpenAI superset
C<none|minimal|low|medium|high|xhigh|max>. Each C<to_*> serializer clamps that
vocabulary to what the target wire actually accepts and returns the body kwargs
to merge into the request.

=cut

has effort => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

=attr effort

The normalized reasoning effort, one of C<none|minimal|low|medium|high|xhigh|max>.

=cut

has model => (
  is      => 'ro',
  isa     => 'Maybe[Str]',
  default => sub { undef },
);

=attr model

Optional model name. Used by L</to_anthropic> to detect always-on
"Fable-class" models (where C<thinking:{type:disabled}> 400s and the
C<thinking> field must be omitted).

=cut

# OpenAI /chat/completions reasoning_effort accepts this subset of the
# normalized vocabulary; max is not accepted there and is dropped.
my %OPENAI_EFFORT = map { $_ => 1 } qw( none minimal low medium high xhigh );

# Anthropic output_config.effort accepts low|medium|high|xhigh|max; the
# normalized none/minimal have no Anthropic equivalent and are dropped.
my %ANTHROPIC_EFFORT = map { $_ => 1 } qw( low medium high xhigh max );

sub _is_fable_class {
  my ( $self ) = @_;
  return ( ( $self->model // '' ) =~ /fable|mythos/i ) ? 1 : 0;
}

# Gemini 3 generationConfig.thinkingConfig.thinkingLevel is low|high
# (gemini-3-pro is low|high only; flash/3.1-pro add medium). Collapse the
# normalized vocabulary to the universally-accepted binary, splitting at high.
sub to_low_high {
  my ( $self ) = @_;
  my $e = $self->effort;
  return ( $e eq 'high' || $e eq 'xhigh' || $e eq 'max' ) ? 'high' : 'low';
}

=method to_low_high

Collapses the normalized effort to Gemini's binary C<low>/C<high>.

=cut

sub to_openai {
  my ( $self ) = @_;
  my $e = $self->effort;
  return () unless $OPENAI_EFFORT{$e};
  return ( reasoning_effort => $e );
}

sub to_responses {
  my ( $self ) = @_;
  return ( reasoning => { effort => $self->effort } );
}

sub to_anthropic {
  my ( $self ) = @_;
  my $e = $self->effort;
  return () unless $ANTHROPIC_EFFORT{$e};
  return (
    output_config => { effort => $e },
    # Adaptive-thinking models need thinking:{type:adaptive} or thinking stays
    # off; always-on "Fable-class" models 400 on thinking:{type:disabled} and
    # need no thinking field at all (thinking is always on).
    ( $self->_is_fable_class ? () : ( thinking => { type => 'adaptive' } ) ),
  );
}

sub to_gemini {
  my ( $self ) = @_;
  return ( thinkingConfig => { thinkingLevel => $self->to_low_high } );
}

# Maps a reasoning_wire_format tag to the per-format serializer method.
my %TO_METHOD = (
  openai    => 'to_openai',
  responses => 'to_responses',
  anthropic => 'to_anthropic',
  gemini    => 'to_gemini',
);

sub to {
  my ( $self, $fmt ) = @_;
  my $method = $TO_METHOD{ $fmt // '' }
    or croak "Langertha::Reasoning: unknown reasoning wire format '" . ( $fmt // '' ) . "'";
  return $self->$method;
}

=method to

    my %kwargs = $r->to($reasoning_wire_format);

Dispatch to the per-format serializer. Returns the body kwargs to merge into
the request (an empty list when the value is unsupported on that wire).

=cut

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Role::ReasoningEffort> - The composed role exposing C<reasoning_effort>

=item * L<Langertha::ToolChoice> - Sibling value object for tool-selection policy

=back

=cut

1;
