package Langertha::ServerToolCall;
# ABSTRACT: Record of one tool call the provider executed itself
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

=head1 SYNOPSIS

    my $response = await $engine->chat_f(
        messages => [ { role => 'user', content => 'Current Perl release?' } ],
        tools    => [ { type => 'web_search' } ],
    );

    for my $call ( @{ $response->server_tool_calls // [] } ) {
        say $call->type, ' ', $call->id, ' ', $call->status // '';
        my $item = $call->data;    # the provider's item, verbatim
    }

=head1 DESCRIPTION

A server-side tool call is one the provider ran itself during the request --
a web search, a file search, a remote MCP call. The client has nothing to do
for it, so it is kept apart from L<Langertha::ToolCall>, which means "a call
the client must act on": these records land on
L<Langertha::Response/server_tool_calls>, never on
L<Langertha::Response/tool_calls>, and C<chat_with_tools_f> never executes
them (ADR 0003 Update k206, ADR 0030).

The record is deliberately thin: the wire item type, its id and status, and
the item itself verbatim under L</data>. Inputs and results are not
normalized across providers.

=cut

has type => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

=attr type

The wire item type, for example C<web_search_call>, C<file_search_call> or
C<mcp_call>. Required.

=cut

has id => (
  is      => 'ro',
  isa     => 'Str',
  default => '',
);

=attr id

The provider's item id. Empty when the item carried none.

=cut

has status => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_status',
);

=attr status

The item status (for example C<completed>), when the provider sent one. Test
with C<has_status>.

=cut

has data => (
  is       => 'ro',
  isa      => 'HashRef',
  required => 1,
);

=attr data

The provider's item, verbatim.

=cut

# Output items of the Responses wire that record a call the provider ran
# (OpenAI create-response reference, spec k206 section 2.1). A client
# tool_search_call (execution => 'client') is client-actionable instead, and
# the walkers croak on it (Langertha::Tool->_croak_on_client_item). Anything
# else unknown is skipped -- values open; it stays on Response.raw.
# x_search_call is xAI's X Search item (docs.x.ai tool-usage-details, k355;
# documentation-derived, not capture-verified).
my %RESPONSES_SERVER_ITEM = map { $_ => 1 } qw(
  web_search_call file_search_call code_interpreter_call image_generation_call
  mcp_call mcp_list_tools shell_call tool_search_call x_search_call
);

sub from_responses {
  my ( $class, $item ) = @_;
  return undef unless ref $item eq 'HASH';
  my $type = $item->{type} // '';
  return undef unless $RESPONSES_SERVER_ITEM{$type};
  return undef if $type eq 'tool_search_call' && ( $item->{execution} // '' ) eq 'client';
  return $class->new(
    type => $type,
    data => $item,
    ( defined $item->{id} && !ref $item->{id} ? ( id => $item->{id} ) : () ),
    ( defined $item->{status} && !ref $item->{status} ? ( status => $item->{status} ) : () ),
  );
}

=method from_responses

    my $call = Langertha::ServerToolCall->from_responses($output_item);

Builds a record from one Responses C<output[]> item, or returns C<undef> when
the item is not a server-side call.

=cut

sub extract {
  my ( $class, $fmt, $data ) = @_;
  croak "Langertha::ServerToolCall: server tool calls on the '" . ( $fmt // '' )
    . "' wire are not supported yet"
    unless ( $fmt // '' ) eq 'responses';
  return () unless ref $data eq 'HASH' && ref $data->{output} eq 'ARRAY';
  return grep { defined } map { $class->from_responses($_) } @{ $data->{output} };
}

=method extract

    my @calls = Langertha::ServerToolCall->extract( responses => $data );

Returns every server-side call item of a decoded response, in wire order.
Pinned to the wire like L<Langertha::ToolCall/extract>. Only C<responses> is
supported; other wires croak.

=cut

sub to_hash {
  my ($self) = @_;
  return {
    type => $self->type,
    id   => $self->id,
    ( $self->has_status ? ( status => $self->status ) : () ),
    data => $self->data,
  };
}

=method to_hash

Returns C<< { type, id, status?, data } >>.

=cut

sub TO_JSON { shift->to_hash }

=method TO_JSON

Delegates to L</to_hash>, for JSON encoders with C<convert_blessed>.

=cut

=seealso

=over

=item * L<Langertha::ServerTool> - the server-side tool definition

=item * L<Langertha::Response/server_tool_calls>

=item * L<Langertha::ToolCall> - calls the client must execute

=back

=cut

__PACKAGE__->meta->make_immutable;
1;
