package Langertha::Raider::Result;
# ABSTRACT: Result object from a Raider raid
our $VERSION = '0.401';
use Moose;
extends 'Langertha::Result';

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

Backward-compatible Raider-specific result class. It now subclasses
L<Langertha::Result> so Raider and Raid orchestration can share the same
result semantics.

=attr type

Inherited from L<Langertha::Result>. One of C<final>, C<question>,
C<pause>, or C<abort>.

=attr text

Inherited from L<Langertha::Result>. Final response text payload.

=attr content

Inherited from L<Langertha::Result>. Question/pause/abort message.

=attr options

Inherited from L<Langertha::Result>. Optional choices for question results.

=method is_final

Inherited predicate helper from L<Langertha::Result>.

=method is_question

Inherited predicate helper from L<Langertha::Result>.

=method is_pause

Inherited predicate helper from L<Langertha::Result>.

=method is_abort

Inherited predicate helper from L<Langertha::Result>.

=cut

__PACKAGE__->meta->make_immutable;

1;
