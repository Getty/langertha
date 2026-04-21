package Langertha::Content;
# ABSTRACT: Base role for canonical multimodal content blocks with cross-provider serialization
our $VERSION = '0.404';
use Moose::Role;

requires qw( to_openai to_anthropic to_gemini );

=head1 SYNOPSIS

    package Langertha::Content::Image;
    use Moose;
    with 'Langertha::Content';

    sub to_openai    { ... }
    sub to_anthropic { ... }
    sub to_gemini    { ... }

=head1 DESCRIPTION

Marker role for canonical content blocks that can be embedded inside the
C<content> arrayref of a chat message and serialized to any provider wire
format by L<Langertha::Role::Chat>.

Implementations must provide C<to_openai>, C<to_anthropic>, and C<to_gemini>,
returning the HashRef block the respective provider expects inside its
message content / parts array.

=seealso

=over

=item * L<Langertha::Content::Image> - Image (URL / base64 / local file) content block

=item * L<Langertha::ToolChoice> - Sibling value object for tool_choice normalization

=back

=cut

1;
