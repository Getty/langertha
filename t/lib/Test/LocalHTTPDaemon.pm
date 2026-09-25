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
#
#   my $server = Test::LocalHTTPDaemon->start($handler, keep_alive => 1);
#   $server->connection_count;   # TCP connections accepted so far
#
# keep_alive => 1 leaves connections open instead: no "Connection: close" is
# added (a raw response must not carry one either) and every connection is
# served by its own forked child, so a client holding a connection open does
# not pin the daemon. This is the mode for connection reuse and HTTP/1.1
# pipelining (Net::Async::HTTP only pipelines on a keep-alive connection).

use strict;
use warnings;

use HTTP::Daemon;
use File::Temp ();
use POSIX ();

sub start {
  my ( $class, $handler, %opts ) = @_;
  my $keep_alive = $opts{keep_alive};
  my $conn_log   = File::Temp->new;   # one line per accepted connection
  my $daemon = HTTP::Daemon->new( LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1 )
    or die "cannot start HTTP::Daemon: $!";
  my $url = $daemon->url;
  $url =~ s{/\z}{};

  my $pid = fork;
  die "fork failed: $!" unless defined $pid;
  if ( !$pid ) {
    $SIG{PIPE} = 'IGNORE';
    my %children;
    if ($keep_alive) {
      $SIG{CHLD} = sub { while ( ( my $done = waitpid( -1, POSIX::WNOHANG() ) ) > 0 ) { delete $children{$done} } };
      $SIG{TERM} = sub { kill 'TERM', keys %children; POSIX::_exit(0) };
    }
    while (1) {
      my $conn = $daemon->accept;
      unless ($conn) { next if $!{EINTR}; last }   # EINTR: a SIGCHLD during accept
      if ( open my $log, '>>', $conn_log->filename ) { print {$log} "conn\n"; close $log }
      if ($keep_alive) {
        my $child = fork;
        die "fork failed: $!" unless defined $child;
        if ($child) { $children{$child} = 1; close $conn; next }
        $SIG{TERM} = 'DEFAULT';
        while ( my $request = $conn->get_request ) {
          my $response = $handler->($request);
          if ( ref $response ) { $conn->send_response($response) }
          else                 { print {$conn} $response }
        }
        POSIX::_exit(0);
      }
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
  return bless { pid => $pid, url => $url, conn_log => $conn_log }, $class;
}

sub url { $_[0]->{url} }

sub connection_count {
  my ($self) = @_;
  open my $fh, '<', $self->{conn_log}->filename or return 0;
  my @lines = <$fh>;
  return scalar @lines;
}

sub DESTROY {
  my ($self) = @_;
  return unless $self->{pid};
  kill 'TERM', $self->{pid};
  waitpid $self->{pid}, 0;
}

1;
