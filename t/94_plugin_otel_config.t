#!/usr/bin/env perl
# ABSTRACT: Langertha::Plugin::OTel configuration from the OTEL_* environment variables (no network)

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;

use Langertha::Engine::Virtual;
use Langertha::Plugin::OTel;
use Langertha::Virtual::Rules qw( answer );

my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );

# Every variable the plugin reads is cleared first, so a developer's own
# OpenTelemetry setup cannot leak into the expectations.
my @VARS = qw(
  OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
  OTEL_EXPORTER_OTLP_HEADERS OTEL_EXPORTER_OTLP_TRACES_HEADERS
  OTEL_EXPORTER_OTLP_PROTOCOL OTEL_EXPORTER_OTLP_TRACES_PROTOCOL
  OTEL_SERVICE_NAME OTEL_RESOURCE_ATTRIBUTES
);

sub plugin {
  my ( %env_and_args ) = @_;
  my $env = delete $env_and_args{env} || {};
  local @ENV{@VARS};
  delete @ENV{@VARS};
  @ENV{ keys %$env } = values %$env;
  my $engine = Langertha::Engine::Virtual->new( langfuse_enabled => 0, fallback => answer('x') );
  my $otel = Langertha::Plugin::OTel->new( host => $engine, %env_and_args );
  # the lazy attributes are read here, while the environment is still set
  $otel->$_ for qw( endpoint headers service_name );
  $otel->_otlp;
  return $otel;
}

sub resource_of {
  my ($otel) = @_;
  my $payload = $json->decode( $otel->_otlp->to_json([]) );
  return { map { $_->{key} => $_->{value}{stringValue} } @{ $payload->{resourceSpans}[0]{resource}{attributes} } };
}

subtest 'defaults' => sub {
  my $otel = plugin();
  is_deeply( $otel->endpoint, 'http://localhost:4318/v1/traces', 'default endpoint is a local collector' );
  is_deeply( $otel->headers, {}, 'no headers' );
  is_deeply( $otel->service_name, 'unknown_service:perl', 'default service name' );
  ok( $otel->enabled, 'enabled by default' );
  ok( !$otel->capture_content, 'capture_content is OFF by default' );
  ok( !$otel->auto_flush, 'auto_flush off by default' );
  ok( !$otel->has_session_id, 'no session id by default' );
  is_deeply( $otel->flush_batch_size, 100, 'flush_batch_size default' );
  is_deeply( $otel->max_batch, 1000, 'max_batch default' );
  is_deeply( $otel->flush_timeout, 10, 'flush_timeout default' );
  is_deeply( resource_of($otel), { 'service.name' => 'unknown_service:perl' }, 'resource: only service.name' );
};

subtest 'endpoint' => sub {
  is_deeply( plugin( env => { OTEL_EXPORTER_OTLP_TRACES_ENDPOINT => 'http://c.example:9/custom/path' } )->endpoint,
    'http://c.example:9/custom/path', 'traces endpoint is used as it is (no /v1/traces appended)' );
  is_deeply( plugin( env => { OTEL_EXPORTER_OTLP_ENDPOINT => 'http://c.example:4318' } )->endpoint,
    'http://c.example:4318/v1/traces', 'generic endpoint gets /v1/traces' );
  is_deeply( plugin( env => { OTEL_EXPORTER_OTLP_ENDPOINT => 'http://c.example:4318/' } )->endpoint,
    'http://c.example:4318/v1/traces', 'one trailing slash stripped' );
  is_deeply( plugin( env => { OTEL_EXPORTER_OTLP_ENDPOINT => 'http://c.example:4318///' } )->endpoint,
    'http://c.example:4318/v1/traces', 'several trailing slashes stripped' );
  is_deeply( plugin( env => {
      OTEL_EXPORTER_OTLP_ENDPOINT        => 'http://generic.example',
      OTEL_EXPORTER_OTLP_TRACES_ENDPOINT => 'http://traces.example/t',
    } )->endpoint, 'http://traces.example/t', 'traces endpoint wins over the generic one' );
  is_deeply( plugin( env => { OTEL_EXPORTER_OTLP_TRACES_ENDPOINT => 'http://traces.example/t/' } )->endpoint,
    'http://traces.example/t/', 'traces endpoint keeps its trailing slash' );
  is_deeply( plugin( env => { OTEL_EXPORTER_OTLP_ENDPOINT => '' } )->endpoint,
    'http://localhost:4318/v1/traces', 'empty variable is ignored' );
  is_deeply( plugin( endpoint => 'http://given', env => { OTEL_EXPORTER_OTLP_TRACES_ENDPOINT => 'http://env' } )->endpoint,
    'http://given', 'explicit endpoint wins over the environment' );
};

subtest 'headers' => sub {
  is_deeply( plugin( env => { OTEL_EXPORTER_OTLP_HEADERS => 'a=1,b=two' } )->headers,
    { a => 1, b => 'two' }, 'k=v pairs, comma separated' );
  is_deeply( plugin( env => { OTEL_EXPORTER_OTLP_HEADERS => 'a=1,b=2', OTEL_EXPORTER_OTLP_TRACES_HEADERS => 'b=3,c=4' } )->headers,
    { a => 1, b => 3, c => 4 }, 'generic and traces headers merge, traces wins' );
  is_deeply( plugin( env => { OTEL_EXPORTER_OTLP_TRACES_HEADERS => 'only=traces' } )->headers,
    { only => 'traces' }, 'traces headers alone' );
  is_deeply( plugin( env => { OTEL_EXPORTER_OTLP_HEADERS => 'Authorization=Basic%20dXNlcjpwdw%3D%3D,x-note=a%2Cb%25c' } )->headers,
    { Authorization => 'Basic dXNlcjpwdw==', 'x-note' => 'a,b%c' }, 'values percent-decoded' );
  is_deeply( plugin( env => { OTEL_EXPORTER_OTLP_HEADERS => ' spaced = value ,novalue,=nokey,k=v=w' } )->headers,
    { spaced => 'value', k => 'v=w' }, 'whitespace trimmed; items without value or key skipped; value keeps further =' );
  is_deeply( plugin( env => { OTEL_EXPORTER_OTLP_HEADERS => 'a=1' }, headers => { b => 2 } )->headers,
    { b => 2 }, 'explicit headers replace the environment ones' );
  is_deeply( plugin( env => { OTEL_EXPORTER_OTLP_HEADERS => 'a=1' }, headers => {} )->headers,
    {}, 'explicit empty headers means none' );
};

subtest 'service name and resource attributes' => sub {
  is_deeply( plugin( env => { OTEL_SERVICE_NAME => 'from-env' } )->service_name, 'from-env', 'OTEL_SERVICE_NAME' );
  is_deeply( plugin( env => { OTEL_SERVICE_NAME => 'from-env' }, service_name => 'given' )->service_name,
    'given', 'explicit service_name wins' );
  is_deeply( resource_of( plugin( env => { OTEL_SERVICE_NAME => 'from-env' } ) )->{'service.name'}, 'from-env',
    'service.name on the wire' );

  my $res = resource_of( plugin( env => {
    OTEL_RESOURCE_ATTRIBUTES => 'service.version=1.2,deployment.environment.name=prod,team=a%20b',
  } ) );
  is_deeply( $res, { 'service.name' => 'unknown_service:perl', 'service.version' => '1.2',
    'deployment.environment.name' => 'prod', team => 'a b' }, 'OTEL_RESOURCE_ATTRIBUTES parsed and decoded' );

  my $merged = resource_of( plugin(
    env                 => { OTEL_RESOURCE_ATTRIBUTES => 'service.version=1.2,keep=env' },
    resource_attributes => { 'service.version' => '9.9', extra => 'arg' },
  ) );
  is_deeply( $merged, { 'service.name' => 'unknown_service:perl', 'service.version' => '9.9', keep => 'env', extra => 'arg' },
    'resource_attributes merged over the environment' );

  my $from_env_name = plugin( env => { OTEL_RESOURCE_ATTRIBUTES => 'service.name=via-resource' } );
  is_deeply( $from_env_name->service_name, 'via-resource', 'service.name from OTEL_RESOURCE_ATTRIBUTES when no OTEL_SERVICE_NAME' );
  is_deeply( resource_of($from_env_name)->{'service.name'}, 'via-resource', '... and on the wire' );

  my $ctor = plugin( env => { OTEL_SERVICE_NAME => 'env' }, resource_attributes => { 'service.name' => 'ctor' } );
  is_deeply( $ctor->service_name, 'ctor', 'constructor resource_attributes service.name wins over OTEL_SERVICE_NAME' );
  is_deeply( resource_of($ctor)->{'service.name'}, 'ctor', '... on the wire' );

  my $explicit = plugin( env => { OTEL_SERVICE_NAME => 'env' }, resource_attributes => { 'service.name' => 'ctor' },
    service_name => 'explicit' );
  is_deeply( $explicit->service_name, 'explicit', 'explicit service_name beats resource_attributes and the environment' );
  is_deeply( resource_of($explicit)->{'service.name'}, 'explicit', '... on the wire' );

  my $both = plugin( env => { OTEL_RESOURCE_ATTRIBUTES => 'service.name=via-resource', OTEL_SERVICE_NAME => 'wins' } );
  is_deeply( $both->service_name, 'wins', 'OTEL_SERVICE_NAME wins over OTEL_RESOURCE_ATTRIBUTES' );
  is_deeply( resource_of($both)->{'service.name'}, 'wins', '... on the wire as well' );
};

subtest 'unsupported protocol warns once' => sub {
  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, $_[0] };
  plugin( env => { OTEL_EXPORTER_OTLP_PROTOCOL => 'http/json' } );
  is_deeply( scalar @warnings, 0, 'http/json: no warning' );
  plugin( env => { OTEL_EXPORTER_OTLP_PROTOCOL => 'grpc' } );
  is_deeply( scalar @warnings, 1, 'grpc: warned' );
  like( $warnings[0], qr/OTEL_EXPORTER_OTLP_PROTOCOL.*grpc.*http\/json/s, 'warning names the variable, value and the supported protocol' );
  plugin( env => { OTEL_EXPORTER_OTLP_TRACES_PROTOCOL => 'http/protobuf' } );
  is_deeply( scalar @warnings, 1, 'warned only once per process' );
};

done_testing;
