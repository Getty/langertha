package Langertha::HTTP::UserAgent;
# ABSTRACT: LWP::UserAgent that keeps credentials on their origin across redirects
our $VERSION = '0.503';
use Moose;
use MooseX::NonMoose;

extends 'LWP::UserAgent';

use Langertha::HTTP::Redirect;

=head1 SYNOPSIS

    my $ua = Langertha::HTTP::UserAgent->new( agent => 'my-app', timeout => 30 );
    my $engine = Langertha::Engine::Anthropic->new( api_key => $key, user_agent => $ua );

=head1 DESCRIPTION

The L<LWP::UserAgent> an engine builds for its synchronous requests
(L<Langertha::Role::HTTP/user_agent>), and so also the one the synchronous
fallback of the C<_f> methods runs over (L<Langertha::Request::SyncHTTP>). It
takes the same constructor arguments as L<LWP::UserAgent> and differs only in
how it follows redirects: through L<Langertha::HTTP::Redirect>, the policy the
L<Net::Async::HTTP> backend follows as well. A redirect to another origin
carries no credential header (of any name) and no credential in the URL; a
redirect from C<https> to C<http> is not followed (karr k374).

Pass one as C<user_agent> when you bring your own agent and want that policy;
a plain L<LWP::UserAgent> keeps LWP's own redirect behaviour.

=cut

sub redirect_ok {
  my ( $self, $referral, $response ) = @_;
  # The policy first, so its refusal (a POST, even one requests_redirectable
  # allows) names its reason on the response; then LWP's own checks.
  return 0 unless Langertha::HTTP::Redirect::guard_referral( $referral, $response );
  return $self->SUPER::redirect_ok( $referral, $response ) ? 1 : 0;
}

=method redirect_ok

LWP's hook, called with the request it is about to send for a redirect.
Applies L<Langertha::HTTP::Redirect/guard_referral> — which refuses every
method but C<GET> and C<HEAD> whatever C<requests_redirectable> says, and
strips the request in place when it goes to another origin — then refuses what
L<LWP::UserAgent/redirect_ok> refuses. A refusal by the policy is named in a
C<Client-Warning> header on the returned 3xx response.

=cut

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::HTTP::Redirect> - The redirect policy

=item * L<Langertha::Role::HTTP> - Builds this agent as C<user_agent>

=back

=cut

1;
