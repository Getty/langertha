package Langertha::MCP::Client;
# ABSTRACT: Reserved namespace — the MCP client moved to Langertha::Raider::MCP

use strict;
use warnings;

1;

__END__

=head1 DESCRIPTION

Reserved namespace placeholder. The async MCP client that used to live here (a
L<Net::Async::MCP> subclass) was extracted to the
L<langertha-raider|https://metacpan.org/dist/langertha-raider> distribution and
renamed L<Langertha::Raider::MCP>. Nothing in Langertha core uses this package;
it is retained only so the C<Langertha::MCP::Client> namespace stays indexed under
the Langertha distribution on CPAN. Core tool-calling (L<Langertha::Role::Tools>)
takes any C<Net::Async::MCP>-compatible client via C<mcp_servers>.

=cut
