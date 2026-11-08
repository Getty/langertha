#!/usr/bin/env perl
# ABSTRACT: Trace and span ids differ between forked processes
use strict;
use warnings;
use Test2::Bundle::More;
use Config;

use Langertha::Trace::OTLP;

plan skip_all => 'fork is not available on this platform'
  unless $Config{d_fork};

# Ids of one child: it takes a trace id and a span id and hands them back.
sub child_ids {
  pipe( my $reader, my $writer ) or die "pipe: $!";
  my $pid = fork;
  die "fork: $!" unless defined $pid;
  if ( !$pid ) {
    close $reader;
    print {$writer} Langertha::Trace::OTLP->new_trace_id, ' ',
      Langertha::Trace::OTLP->new_span_id, "\n";
    close $writer;
    require POSIX;
    POSIX::_exit(0);
  }
  close $writer;
  my $line = <$reader>;
  close $reader;
  waitpid $pid, 0;
  chomp $line;
  return split / /, $line;
}

sub check_children {
  my ($label) = @_;
  # The parent draws first, so the generator is set up before the forks.
  my $parent_trace = Langertha::Trace::OTLP->new_trace_id;
  Langertha::Trace::OTLP->new_span_id;
  my @first  = child_ids();
  my @second = child_ids();
  like( $first[0], qr/\A[0-9a-f]{32}\z/, "$label: child trace id is 32 hex" );
  like( $first[1], qr/\A[0-9a-f]{16}\z/, "$label: child span id is 16 hex" );
  isnt( $first[0], $second[0], "$label: two children get different trace ids" );
  isnt( $first[1], $second[1], "$label: two children get different span ids" );
  isnt( $first[0], $parent_trace, "$label: a child does not repeat the parent's id" );
}

SKIP: {
  skip 'no /dev/urandom', 5 unless -r '/dev/urandom';
  check_children('urandom');
}

{
  # The rand() fallback, as on a system without /dev/urandom.
  local $Langertha::Trace::OTLP::URANDOM = 0;
  check_children('rand fallback');
  like( Langertha::Trace::OTLP->new_trace_id, qr/\A[0-9a-f]{32}\z/,
    'rand fallback: trace id is 32 hex' );
}

done_testing;
