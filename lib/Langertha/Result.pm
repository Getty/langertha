package Langertha::Result;
# ABSTRACT: Reserved namespace — the result value object moved to Langertha::Raider::Result
our $VERSION = '0.504';
use strict;
use warnings;

1;

__END__

=head1 DESCRIPTION

Reserved namespace placeholder. The result value object that used to live here
(C<final> / C<question> / C<pause> / C<abort>, boolean-true-because-it-exists) was
extracted to the L<langertha-raider|https://metacpan.org/dist/langertha-raider>
distribution, where it is self-contained as L<Langertha::Raider::Result>. Nothing
in Langertha core uses this package; it is retained only so the C<Langertha::Result>
namespace stays indexed under the Langertha distribution on CPAN.

=cut
