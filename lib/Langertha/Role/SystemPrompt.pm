package Langertha::Role::SystemPrompt;
# ABSTRACT: Role for APIs with system prompt
our $VERSION = '0.202';
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

=item * L<Langertha::Role::Chat> - Chat role that injects the system prompt into messages

=item * L<Langertha::Raider> - Autonomous agent with its own C<mission> prompt

=back

=cut

1;
