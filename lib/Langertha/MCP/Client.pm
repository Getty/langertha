package Langertha::MCP::Client;
# ABSTRACT: Async MCP client speaking the current protocol revision, wrapping Net::Async::MCP
our $VERSION = '0.503';
use Moose;
extends 'Net::Async::MCP';
use Future::AsyncAwait;

=head1 SYNOPSIS

    use IO::Async::Loop;
    use Langertha::MCP::Client;
    use Future::AsyncAwait;

    my $loop = IO::Async::Loop->new;

    # In-process transport (Perl MCP::Server in same process)
    use MCP::Server;
    my $server = MCP::Server->new(name => 'MyServer');

    my $mcp = Langertha::MCP::Client->new(server => $server);
    $loop->add($mcp);

    async sub main {
        await $mcp->initialize;
        my $tools = await $mcp->list_tools;
        await $mcp->shutdown;
    }

    main()->get;

=head1 DESCRIPTION

L<Langertha::MCP::Client> is a drop-in subclass of L<Net::Async::MCP> that
upgrades the client to the current MCP protocol revision (Rev-2026-07-28).

I<Temporary upstream workaround.> Net::Async::MCP 0.003 hardcodes the obsolete
top-level C<protocolVersion =E<gt> '2025-11-25'> form in its C<initialize>
request and sends no C<_meta> on any other request. Current MCP servers
(Rev-2026-07-28) require the C<_meta> object — C<io.modelcontextprotocol/
protocolVersion> plus C<io.modelcontextprotocol/clientCapabilities> — on
I<every> request, and no longer implement an C<initialize> method at all: the
handshake is now C<server/discover>, and C<initialize> exists only in the
legacy shim (reachable only by transports that classify a request as legacy —
the in-process transport does not). Against such a server the upstream client
fails every request with a JSON-RPC error (missing/unsupported protocol
version, or method not found), which the transports turn into a failed Future.

This subclass therefore overrides the whole request surface: L</initialize>
performs the C<server/discover> handshake with C<_meta> (storing
C<server_info> from the response C<_meta>, C<server_capabilities> from the
response C<capabilities>), and L</list_tools> / L</call_tool> / L</list_prompts>
/ L</get_prompt> / L</list_resources> / L</read_resource> / L</ping> carry
C<_meta> on every request. The spec strings are hardcoded (no dependency on
C<MCP::Constants> / the MCP server dist). Once upstream ships a client that
speaks the current protocol, remove this subclass and revert the call sites to
C<Net::Async::MCP-E<gt>new>.

=cut

# Rev-2026-07-28 `_meta` payload — the protocol version and client
# capabilities every current-spec request must declare (MCP::Constants
# META_PROTOCOL_VERSION / META_CLIENT_CAPABILITIES). Keep the version string
# '2026-07-28': MCP::Server (SUPPORTED_VERSIONS) accepts only that one.
my %MCP_META = (
  'io.modelcontextprotocol/protocolVersion'    => '2026-07-28',
  'io.modelcontextprotocol/clientCapabilities' => {},
);

async sub initialize {
  my ( $self ) = @_;
  $self->_ensure_transport;

  # Current protocol handshake. `initialize` no longer exists in the current
  # protocol — only in the legacy shim, which the in-process transport never
  # engages (it hands every request a fresh context with no `legacy`). The
  # server echoes its info in the response `_meta`.
  my $result = await $self->{transport}->send_request('server/discover', {
    _meta => { %MCP_META },
  });

  $self->{server_info} = $result->{_meta}{'io.modelcontextprotocol/serverInfo'};
  $self->{server_capabilities} = $result->{capabilities};
  $self->{_initialized} = 1;

  # The parent sends a `notifications/initialized` notification here; the
  # current protocol has no such notification (notifications are a
  # subscriptions/listen concern), so it is deliberately not sent.

  return $result;
}

=method initialize

    my $result = await $mcp->initialize;

Performs the MCP initialization handshake using the current protocol: sends
C<server/discover> with C<_meta> and stores the server info (from the response
C<_meta>) and capabilities. Returns the C<server/discover> result hashref and
populates C<server_info> / C<server_capabilities>, like the parent's
C<initialize> did. (Net::Async::MCP 0.003 instead sends the obsolete
C<initialize> request, which current MCP servers reject.)

=cut

async sub list_tools {
  my ( $self ) = @_;
  my $result = await $self->{transport}->send_request('tools/list', {
    _meta => { %MCP_META },
  });
  return $result->{tools} // [];
}

=method list_tools

    my $tools = await $mcp->list_tools;

Returns an ArrayRef of tool definition hashrefs from the MCP server, declaring
the client protocol version and capabilities in C<_meta> (required by current
servers). Otherwise identical to the parent.

=cut

async sub call_tool {
  my ( $self, $name, $arguments ) = @_;
  my $result = await $self->{transport}->send_request('tools/call', {
    name      => $name,
    arguments => $arguments // {},
    _meta     => { %MCP_META },
  });
  return $result;
}

=method call_tool

    my $result = await $mcp->call_tool($name, \%arguments);

Calls a named tool on the MCP server with the given arguments hashref, carrying
C<_meta> like L</list_tools>. Returns a hashref with C<content> and C<isError>.

=cut

async sub list_prompts {
  my ( $self ) = @_;
  my $result = await $self->{transport}->send_request('prompts/list', {
    _meta => { %MCP_META },
  });
  return $result->{prompts} // [];
}

=method list_prompts

    my $prompts = await $mcp->list_prompts;

Returns an ArrayRef of prompt definition hashrefs from the MCP server, carrying
C<_meta> on the request.

=cut

async sub get_prompt {
  my ( $self, $name, $arguments ) = @_;
  my $result = await $self->{transport}->send_request('prompts/get', {
    name      => $name,
    arguments => $arguments // {},
    _meta     => { %MCP_META },
  });
  return $result;
}

=method get_prompt

    my $result = await $mcp->get_prompt($name, \%arguments);

Retrieves a named prompt from the MCP server, optionally passing arguments,
carrying C<_meta> on the request.

=cut

async sub list_resources {
  my ( $self ) = @_;
  my $result = await $self->{transport}->send_request('resources/list', {
    _meta => { %MCP_META },
  });
  return $result->{resources} // [];
}

=method list_resources

    my $resources = await $mcp->list_resources;

Returns an ArrayRef of resource definition hashrefs from the MCP server,
carrying C<_meta> on the request.

=cut

async sub read_resource {
  my ( $self, $uri ) = @_;
  my $result = await $self->{transport}->send_request('resources/read', {
    uri   => $uri,
    _meta => { %MCP_META },
  });
  return $result;
}

=method read_resource

    my $result = await $mcp->read_resource($uri);

Reads a resource by URI from the MCP server, carrying C<_meta> on the request.

=cut

async sub ping {
  my ( $self ) = @_;
  await $self->{transport}->send_request('ping', { _meta => { %MCP_META } });
  return 1;
}

=method ping

    await $mcp->ping;

Sends a ping request to verify the server is alive and responsive, carrying
C<_meta> on the request. Returns C<1> on success.

=cut

__PACKAGE__->meta->make_immutable( inline_constructor => 0 );

=seealso

=over

=item * L<Net::Async::MCP> - The parent async MCP client this subclasses

=item * L<Langertha::Role::Tools> - MCP tool-calling role using this client

=item * L<Langertha::Raider> - Autonomous agent using this client for its inline MCP server

=back

=cut

1;
