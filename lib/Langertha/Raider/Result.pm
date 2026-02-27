package Langertha::Raider::Result;
# ABSTRACT: Result object from a Raider raid
our $VERSION = '0.302';
use Moose;

use overload
  '""' => sub { $_[0]->text // '' },
  fallback => 1;

=head1 SYNOPSIS

    my $result = await $raider->raid_f('What files are here?');

    # Stringifies to text (backward compatible)
    say $result;

    # Check result type
    if ($result->is_final) {
        say "Final answer: $result";
    } elsif ($result->is_question) {
        say "Agent asks: " . $result->content;
        my $answer = <STDIN>;
        my $continued = await $raider->respond_f($answer);
    } elsif ($result->is_pause) {
        say "Agent paused: " . $result->content;
        my $continued = await $raider->respond_f('continue');
    } elsif ($result->is_abort) {
        say "Agent aborted: " . $result->content;
    }

=head1 DESCRIPTION

Wraps the outcome of a L<Langertha::Raider/raid_f> call. The C<type> field
indicates what happened:

=over 4

=item C<final> - The LLM produced a final text answer (in C<text>).

=item C<question> - The agent used C<raider_ask_user> and needs a response
(question in C<content>, optional choices in C<options>).

=item C<pause> - The agent used C<raider_pause> and is waiting to be resumed
(reason in C<content>).

=item C<abort> - The agent used C<raider_abort> and stopped (reason in C<content>).

=back

Uses C<overload> so stringification returns C<text>, preserving backward
compatibility with code that treats raid results as plain strings.

=cut

has type => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

=attr type

Result type: C<final>, C<question>, C<pause>, or C<abort>.

=cut

has text => (
  is  => 'ro',
  isa => 'Str',
  predicate => 'has_text',
);

=attr text

The final text answer from the LLM. Only set when C<type> is C<final>.

=cut

has content => (
  is  => 'ro',
  isa => 'Str',
  predicate => 'has_content',
);

=attr content

The question, pause reason, or abort reason. Set for non-final result types.

=cut

has options => (
  is  => 'ro',
  isa => 'ArrayRef',
  predicate => 'has_options',
);

=attr options

Optional list of choices for a C<question> result.

=cut

sub is_final    { $_[0]->type eq 'final' }
sub is_question { $_[0]->type eq 'question' }
sub is_pause    { $_[0]->type eq 'pause' }
sub is_abort    { $_[0]->type eq 'abort' }

=method is_final

Returns true if this is a final text answer.

=method is_question

Returns true if the agent is asking the user a question.

=method is_pause

Returns true if the agent has paused.

=method is_abort

Returns true if the agent has aborted.

=cut

__PACKAGE__->meta->make_immutable;

1;
