package Test::LocalHTTPDaemon;
# Forked HTTP::Daemon on 127.0.0.1 for exercising a real LWP::UserAgent /
# Net::Async::HTTP against canned responses — no live provider calls.
#
#   my $server = Test::LocalHTTPDaemon->start(sub { my ($request) = @_; return $http_response });
#   my $base   = $server->url;   # http://127.0.0.1:PORT (no trailing slash)
#
# Every response is sent with "Connection: close", so a keep-alive client
# (Net::Async::HTTP) never pins the single-threaded daemon between tests. A
# response whose content is a CODE ref is sent chunked (HTTP::Daemon), one
# chunk per call until it returns an empty string/undef.

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
        $conn->send_response( $handler->($request) );
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
