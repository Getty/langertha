package Langertha::Request::HTTP;
# ABSTRACT: A HTTP Request inside of Langertha
our $VERSION = '0.101';
use Moose;
use MooseX::NonMoose;

extends 'HTTP::Request';

=head1 SYNOPSIS

    # Created internally by Langertha::Role::HTTP
    my $request = Langertha::Request::HTTP->new(
        http => [ 'POST', $url, $headers, $body ],
        request_source => $engine,
        response_call  => sub { ... },
    );

=head1 DESCRIPTION

A subclass of L<HTTP::Request> that carries two extra pieces of Langertha
context: the engine object that created the request (C<request_source>) and
a callback to parse the HTTP response into the appropriate return value
(C<response_call>).

Constructed internally by L<Langertha::Role::HTTP/generate_http_request> and
dispatched by L<Langertha::Role::Chat>. You normally do not need to create
these directly.

=cut

has request_source => (
  is => 'ro',
  does => 'Langertha::Role::HTTP',
);

=attr request_source

The engine object that created this request. Must consume
L<Langertha::Role::HTTP>.

=cut

has response_call => (
  is => 'ro',
  isa => 'CodeRef',
);

=attr response_call

A CodeRef that accepts an L<HTTP::Response> and returns the parsed result
expected by the caller. Invoked by L<Langertha::Role::Chat/simple_chat> after
a successful response.

=cut

sub FOREIGNBUILDARGS {
  my ( $class, %args ) = @_;
  return @{$args{http}};
}

sub BUILDARGS {
  my ( $class, %args ) = @_;
  delete $args{http};
  return { %args };
}

=seealso

=over

=item * L<Langertha> - Main Langertha documentation

=item * L<Langertha::Role::HTTP> - Creates instances of this class

=item * L<Langertha::Role::Chat> - Dispatches the request and calls C<response_call>

=back

=cut

1;