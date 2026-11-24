#!/usr/bin/env perl
# ABSTRACT: the distribution requires perl 5.24, in the cpanfile and in what dzil builds from it
use strict; use warnings;
use Test2::Bundle::More;
use FindBin;
use CPAN::Meta;

# Langertha needs perl 5.24: Future::AsyncAwait passes a cancel on to the
# awaited future only from there on, so on an older perl a cancelled stream
# or image prefetch kept running (t/45_async_http_stream_die,
# t/47_image_prefetch_timeout).
my $root = "$FindBin::Bin/..";

sub slurp {
  my ($file) = @_;
  open my $fh, '<', $file or die "$file: $!";
  local $/;
  return scalar <$fh>;
}

# Top level (column 0), so not a requirement of one phase such as test.
like( slurp("$root/cpanfile"), qr/^requires 'perl', '5\.024';/m,
  'the cpanfile requires perl 5.024 at runtime' );

SKIP: {
  skip 'no META.json: a git checkout, not a distribution built by dzil', 2
    unless -e "$root/META.json";
  my $meta = CPAN::Meta->load_file("$root/META.json");
  is( $meta->effective_prereqs->requirements_for( 'runtime', 'requires' )
        ->requirements_for_module('perl'),
    '5.024', 'META.json: runtime requires perl 5.024' );
  like( slurp("$root/Makefile.PL"), qr/"MIN_PERL_VERSION" => "5\.024"/,
    'Makefile.PL refuses a perl older than 5.024' );
}

done_testing;
