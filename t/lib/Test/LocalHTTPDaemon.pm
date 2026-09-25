package Test::LocalHTTPDaemon;
# Forked HTTP::Daemon on 127.0.0.1 for exercising a real LWP::UserAgent /
# Net::Async::HTTP against canned responses — no live provider calls.
#
#   my $server = Test::LocalHTTPDaemon->start(sub { my ($request) = @_; return $http_response });
#   my $base   = $server->url;   # http://127.0.0.1:PORT (no trailing slash)
#
# Every response is sent with "Connection: close" (a raw response has to carry
# that header itself), so a keep-alive client (Net::Async::HTTP) never pins the
# single-threaded daemon between tests, nor reuses a connection the daemon has
# already hung up on. A response whose content is a CODE ref is sent chunked (HTTP::Daemon), one
# chunk per call until it returns an empty string/undef. A handler that returns
# a plain string instead of an HTTP::Response has it written verbatim, in one
# write, as the complete raw response (status line, headers and framed body):
# the way to control exactly which bytes reach the client in a single read.

use strict;
use warnings;

use HTTP::Daemon;
use POSIX ();

sub start {
  my ( $class, $handler ) = @_;
  my $daemon = HTTP::Daemon->new( LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1 )
    or die "cannot start HTTP::Daemon: $!";
  my $url = $daemon->url;
  $url =~ s{/\z}{};

  my $pid = fork;
  die "fork failed: $!" unless defined $pid;
  if ( !$pid ) {
    $SIG{PIPE} = 'IGNORE';
    while ( my $conn = $daemon->accept ) {
      while ( my $request = $conn->get_request ) {
        $conn->force_last_request;
        my $response = $handler->($request);
        # force_last_request only makes the daemon hang up; the header is what
        # tells the client not to reuse the connection.
        if ( ref $response ) { $response->header( Connection => 'close' ); $conn->send_response($response) }
        else                 { print {$conn} $response }
      }
      $conn->close;
    }
    POSIX::_exit(0);   # skip END blocks (Test2) in the child
  }

  close $daemon;
  return bless { pid => $pid, url => $url }, $class;
}

sub url { $_[0]->{url} }

sub DESTROY {
  my ($self) = @_;
  return unless $self->{pid};
  kill 'TERM', $self->{pid};
  waitpid $self->{pid}, 0;
}

1;
