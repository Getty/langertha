package Langertha::Content;
# ABSTRACT: Base role for canonical multimodal content blocks with cross-provider serialization
our $VERSION = '0.503';
use Moose::Role;

requires qw( to_openai to_anthropic to_gemini to_responses to_ollama to_lmstudio );

=head1 SYNOPSIS

    package Langertha::Content::Image;
    use Moose;
    with 'Langertha::Content';

    sub to_openai    { ... }
    sub to_anthropic { ... }
    sub to_gemini    { ... }
    sub to_responses { ... }
    sub to_ollama    { ... }
    sub to_lmstudio  { ... }

=head1 DESCRIPTION

Marker role for canonical content blocks that can be embedded inside the
C<content> arrayref of a chat message and serialized to any provider wire
format by L<Langertha::Role::Chat>.

Implementations must provide C<to_openai>, C<to_anthropic>, C<to_gemini>,
C<to_responses>, C<to_ollama> and C<to_lmstudio> (one per
L<Langertha::Role::Chat/content_format>), returning what the respective wire
expects for the block: a HashRef for the message content / parts / input
array, or (C<to_ollama>) the raw base64 string for the message C<images>
array.

=seealso

=over

=item * L<Langertha::Content::Image> - Image (URL / base64 / local file) content block

=item * L<Langertha::ToolChoice> - Sibling value object for tool_choice normalization

=back

=cut

1;
