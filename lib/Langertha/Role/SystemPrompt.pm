package Langertha::Role::SystemPrompt;
# ABSTRACT: Role for APIs with system prompt
our $VERSION = '0.101';
use Moose::Role;

has system_prompt => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_system_prompt',
);

=attr system_prompt

An optional system prompt string. When set, it is automatically prepended to
the conversation as a C<system> role message by L<Langertha::Role::Chat/chat_messages>.

=cut

=seealso

=over

=item * L<Langertha> - Main Langertha documentation

=item * L<Langertha::Role::Chat> - Chat role that injects this into messages

=back

=cut

1;
