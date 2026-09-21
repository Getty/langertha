#!/usr/bin/env perl
# ABSTRACT: Role::AsyncHTTP picks injected > Net::Async::HTTP > sync shim (warn once)
use strict; use warnings;
use Test2::Bundle::More;

{
  package FakeEngine;
  use Moose;
  has user_agent => (is => 'ro', default => sub { bless {}, 'FakeUA' });
  with 'Langertha::Role::AsyncHTTP';
  __PACKAGE__->meta->make_immutable;
}

# injected client wins
{
  my $injected = bless {}, 'MyClient';
  my $engine = FakeEngine->new( _async_http => $injected );
  is($engine->_async_http, $injected, 'injected _async_http is used verbatim');
}

# no Net::Async::HTTP -> sync shim + exactly one warning
{
  local @INC = (sub {
    my (undef, $file) = @_;
    die "blocked\n" if $file eq 'Net/Async/HTTP.pm';
    return;
  }, @INC);
  my @warnings; local $SIG{__WARN__} = sub { push @warnings, "@_" };
  my $engine = FakeEngine->new;
  isa_ok($engine->_async_http, ['Langertha::Request::SyncHTTP'], 'falls back to sync shim');
  my $engine2 = FakeEngine->new;
  $engine2->_async_http;
  is(scalar(grep { /synchronous/i } @warnings), 1, 'warns exactly once per process');
}

done_testing;
