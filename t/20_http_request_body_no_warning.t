#!/usr/bin/env perl
# ABSTRACT: generate_http_request puts the arguments in the body without a warning, on every perl

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;

use Langertha::Engine::OpenAI;

# Before perl 5.26 a hash in scalar context is its bucket ratio ("2/8"), not
# its key count. A numeric test on it warns 'Argument "2/8" isn't numeric' on
# every request that has a body, so on those perls each request warned, and
# every test that asserts "no warning" failed (karr k418). Whether a body is
# built must depend only on whether there are arguments.

my $json   = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );
my $engine = Langertha::Engine::OpenAI->new( api_key => 'test-key', model => 'gpt-test' );
my $url    = 'https://api.example.invalid/v1/chat/completions';

sub request_with_warnings {
  my (@args) = @_;
  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, $_[0] };
  my $request = $engine->generate_http_request( POST => $url, sub { }, @args );
  return ( $request, \@warnings );
}

subtest 'one argument: JSON body, no warning' => sub {
  my ( $request, $warnings ) = request_with_warnings( model => 'gpt-test' );
  is_deeply( $warnings, [], 'no warning' );
  is_deeply( $json->decode( $request->content ), { model => 'gpt-test' }, 'the argument is the body' );
};

subtest 'several arguments: JSON body, no warning' => sub {
  my %args = map { ( "key$_" => $_ ) } 1 .. 9;
  my ( $request, $warnings ) = request_with_warnings(%args);
  is_deeply( $warnings, [], 'no warning' );
  is_deeply( $json->decode( $request->content ), \%args, 'every argument is in the body' );
};

subtest 'no arguments: no body, no warning' => sub {
  my ( $request, $warnings ) = request_with_warnings();
  is_deeply( $warnings, [], 'no warning' );
  is( $request->content, '', 'no body' );
};

subtest 'a whole chat request: no warning' => sub {
  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, $_[0] };
  my $request = $engine->chat('Hello');
  is_deeply( \@warnings, [], 'no warning' );
  is( $json->decode( $request->content )->{model}, 'gpt-test', 'the request carries its body' );
};

done_testing;
