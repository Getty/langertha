package Langertha::Result;
# ABSTRACT: Common result object for Raider and Raid execution
our $VERSION = '0.402';
use Moose;

use overload
  '""' => sub { $_[0]->text // '' },
  fallback => 1;

=head1 SYNOPSIS

    my $r = Langertha::Result->final('done');

    if ($r->is_question) {
      ...
    }

    say "$r"; # stringifies to text (or empty string)

=head1 DESCRIPTION

Unified result type used by runnable nodes in Langertha orchestration.
Represents one of four high-level outcomes:

=over 4

=item * C<final> - successful completion

=item * C<question> - needs user input

=item * C<pause> - intentionally paused / resumable

=item * C<abort> - explicit stop / error

=back

L<Langertha::Raider::Result> subclasses this class for backward-compatible
Raider behavior.

=cut

has type => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

=attr type

Result type: C<final>, C<question>, C<pause>, or C<abort>.

=cut

has text => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_text',
);

=attr text

Final output text, usually used with C<type =E<gt> final>.

=cut

has content => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_content',
);

=attr content

Auxiliary text payload for non-final outcomes (question/pause/abort).

=cut

has options => (
  is        => 'ro',
  isa       => 'ArrayRef',
  predicate => 'has_options',
);

=attr options

Optional choices for question-style results.

=cut

has data => (
  is        => 'ro',
  predicate => 'has_data',
);

=attr data

Optional structured payload for callers/orchestrators.

=cut

has context => (
  is        => 'ro',
  predicate => 'has_context',
);

=attr context

Optional run context attached to the result.

=cut

sub is_final    { $_[0]->type eq 'final' }
sub is_question { $_[0]->type eq 'question' }
sub is_pause    { $_[0]->type eq 'pause' }
sub is_abort    { $_[0]->type eq 'abort' }

=method is_final

Returns true for C<type =E<gt> final>.

=method is_question

Returns true for C<type =E<gt> question>.

=method is_pause

Returns true for C<type =E<gt> pause>.

=method is_abort

Returns true for C<type =E<gt> abort>.

=cut

sub as_hash {
  my ( $self ) = @_;
  return {
    type    => $self->type,
    ($self->has_text    ? ( text    => $self->text )    : ()),
    ($self->has_content ? ( content => $self->content ) : ()),
    ($self->has_options ? ( options => $self->options ) : ()),
    ($self->has_data    ? ( data    => $self->data )    : ()),
  };
}

=method as_hash

Returns a plain hashref representation (without C<context>).

=cut

sub with_context {
  my ( $self, $context ) = @_;
  return ref($self)->new(
    %{$self->as_hash},
    context => $context,
  );
}

=method with_context

    my $with_ctx = $result->with_context($ctx);

Returns a cloned result object with C<context> attached.

=cut

sub final {
  my ( $class, $text, %args ) = @_;
  return $class->new(
    type => 'final',
    (defined $text ? ( text => "$text" ) : ()),
    %args,
  );
}

sub question {
  my ( $class, $content, %args ) = @_;
  return $class->new(
    type    => 'question',
    content => "$content",
    %args,
  );
}

sub pause {
  my ( $class, $content, %args ) = @_;
  return $class->new(
    type    => 'pause',
    content => "$content",
    %args,
  );
}

sub abort {
  my ( $class, $content, %args ) = @_;
  return $class->new(
    type    => 'abort',
    content => "$content",
    %args,
  );
}

=method final

    my $r = Langertha::Result->final('ok');

Constructor helper for final results.

=method question

    my $r = Langertha::Result->question('Which option?', options => ['a','b']);

Constructor helper for question results.

=method pause

    my $r = Langertha::Result->pause('Waiting for external event');

Constructor helper for pause results.

=method abort

    my $r = Langertha::Result->abort('Cannot continue');

Constructor helper for abort results.

=cut

__PACKAGE__->meta->make_immutable;

1;
