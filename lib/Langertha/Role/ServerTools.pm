package Langertha::Role::ServerTools;
# ABSTRACT: Role for an engine whose wire accepts provider-native server-side tools
our $VERSION = '0.503';
use Moose::Role;
use Langertha::ServerTool;

=head1 SYNOPSIS

    my $engine = Langertha::Engine::OpenAIResponses->new(
        api_key      => $ENV{OPENAI_API_KEY},
        model        => 'gpt-5.6-luna',
        server_tools => [ { type => 'web_search' } ],   # sent on every request
    );

    say 'server tools ok' if $engine->supports('server_tools');

=head1 DESCRIPTION

Marks an engine whose wire takes provider-native server-side tool entries in
C<tools> -- tools the provider runs itself, such as C<web_search> -- and
contributes the C<server_tools> capability flag (ADR 0002). The flag says
I<that> the wire accepts them, not I<which> types a given model honors.

The role holds the per-engine default list (L</server_tools>) and the
L</_server_tool_wire_check> hook. The wire envelope that consumes the engine
(L<Langertha::Role::ResponsesCompatible>) appends the defaults to every
request, so C<simple_chat>, C<chat_f> and C<chat_with_tools_f> all send them.
It does not require L<Langertha::Role::Tools>.

Server-side calls come back on L<Langertha::Response/server_tool_calls>; see
L<Langertha::ServerTool> and ADR 0030.

=cut

has server_tools => (
  is      => 'ro',
  isa     => 'ArrayRef',
  default => sub { [] },
);

=attr server_tools

    server_tools => [ { type => 'web_search' }, $server_tool_object ]

Server-side tools sent with every chat request of this engine, after any
C<tools> of the request itself. Each entry is a L<Langertha::ServerTool> or a
provider-native hash that L<Langertha::ServerTool/from_hash> recognises for
the engine's wire; anything else (a bare string such as C<'web_search'>, a
function tool, a type Langertha does not list) croaks when the request is
built. Wrap an unlisted type as
C<< Langertha::ServerTool->new( wire => ..., spec => ..., unlisted => 1 ) >>.

B<The request wins.> A default is left out when the request's own C<tools>
already carry a server tool of the same kind: the same C<type>, and for
C<mcp> the same C<server_label> as well. So a per-request
C<< { type => 'web_search', search_context_size => 'high' } >> replaces a
default C<web_search> instead of sending it twice.

Defaults to an empty ArrayRef.

=cut

sub _server_tool_wire_check {
  my ( $self, $server_tool ) = @_;
  return $server_tool->to( $server_tool->wire );
}

=method _server_tool_wire_check

    my $spec = $engine->_server_tool_wire_check($server_tool);

Engine hook, called once per L<Langertha::ServerTool> while a request is
built. Returns the native hash to send; may croak or rewrite it where the
provider diverges from the shared wire. The default returns the tool's native
hash unchanged. It runs after L<Langertha::ServerTool/to>, which already
refuses a remote C<mcp> tool without C<< require_approval => 'never' >>.

=cut

=seealso

=over

=item * L<Langertha::ServerTool>

=item * L<Langertha::ServerToolCall>

=item * L<Langertha::Role::Capabilities> - the C<server_tools> flag

=back

=cut

1;
