#!/usr/bin/env perl
# ABSTRACT: Test Langertha::Role::Langfuse with mock HTTP

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;
use MIME::Base64 qw( decode_base64 );

# Langfuse is built into every engine via Role::Chat — no subclass needed

use Langertha::Engine::OpenAI;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

# --- Langfuse disabled by default ---

my $engine_no_lf = Langertha::Engine::OpenAI->new(
  api_key => 'testkey',
  model   => 'gpt-4o-mini',
);
ok(!$engine_no_lf->langfuse_enabled, 'Langfuse disabled without keys');

my $trace_id = $engine_no_lf->langfuse_trace(name => 'test');
is($trace_id, undef, 'langfuse_trace returns undef when disabled');

$engine_no_lf->langfuse_generation(trace_id => 'fake', name => 'test');
is(scalar @{$engine_no_lf->_langfuse_batch}, 0, 'no events batched when disabled');

# --- Langfuse enabled with keys ---

my $engine = Langertha::Engine::OpenAI->new(
  api_key             => 'testkey',
  model               => 'gpt-4o-mini',
  langfuse_public_key => 'pk-lf-test123',
  langfuse_secret_key => 'sk-lf-secret456',
  langfuse_url        => 'https://langfuse.test.invalid',
);
ok($engine->langfuse_enabled, 'Langfuse enabled with both keys');

# --- Also works with other engines ---

{
  require Langertha::Engine::Anthropic;
  my $claude = Langertha::Engine::Anthropic->new(
    api_key             => 'testkey',
    langfuse_public_key => 'pk-test',
    langfuse_secret_key => 'sk-test',
  );
  ok($claude->langfuse_enabled, 'Langfuse works on Anthropic engine');
  ok($claude->can('langfuse_flush'), 'Anthropic engine has langfuse_flush');
}

# --- Create trace ---

my $tid = $engine->langfuse_trace(
  name   => 'test-trace',
  input  => { query => 'hello' },
  output => 'world',
);
ok($tid, 'langfuse_trace returns an ID');
like($tid, qr/^[0-9a-f-]+$/, 'trace ID looks like a UUID');

is(scalar @{$engine->_langfuse_batch}, 1, 'one event in batch');
my $trace_event = $engine->_langfuse_batch->[0];
is($trace_event->{type}, 'trace-create', 'event type is trace-create');
is($trace_event->{body}{name}, 'test-trace', 'trace name set');
is_deeply($trace_event->{body}{input}, { query => 'hello' }, 'trace input set');
is($trace_event->{body}{output}, 'world', 'trace output set');
like($trace_event->{timestamp}, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/,
  'timestamp in ISO 8601 format');

# --- Create generation ---

my $gid = $engine->langfuse_generation(
  trace_id   => $tid,
  name       => 'test-gen',
  model      => 'gpt-4o-mini',
  input      => 'prompt',
  output     => 'response',
  usage      => { input => 10, output => 5, total => 15 },
  start_time => '2026-02-22T10:00:00.000Z',
  end_time   => '2026-02-22T10:00:01.500Z',
);
ok($gid, 'langfuse_generation returns an ID');

is(scalar @{$engine->_langfuse_batch}, 2, 'two events in batch');
my $gen_event = $engine->_langfuse_batch->[1];
is($gen_event->{type}, 'generation-create', 'event type is generation-create');
is($gen_event->{body}{traceId}, $tid, 'generation linked to trace');
is($gen_event->{body}{name}, 'test-gen', 'generation name set');
is($gen_event->{body}{model}, 'gpt-4o-mini', 'generation model set');
is($gen_event->{body}{input}, 'prompt', 'generation input set');
is($gen_event->{body}{output}, 'response', 'generation output set');
is_deeply($gen_event->{body}{usage}, { input => 10, output => 5, total => 15 },
  'generation usage set');
is($gen_event->{body}{startTime}, '2026-02-22T10:00:00.000Z', 'generation startTime set');
is($gen_event->{body}{endTime}, '2026-02-22T10:00:01.500Z', 'generation endTime set');

# --- Verify batch structure for ingestion ---

my $batch = $engine->_langfuse_batch;
is(scalar @$batch, 2, 'batch has 2 events');

# Verify the JSON payload would be valid
my $payload = $json->encode({ batch => $batch });
my $decoded = $json->decode($payload);
is(scalar @{$decoded->{batch}}, 2, 'payload batch decodes correctly');

# --- Generation requires trace_id ---

eval { $engine->langfuse_generation(name => 'no-trace') };
like($@, qr/requires trace_id/, 'generation without trace_id croaks');

# --- flush clears batch ---
# (We don't actually send HTTP in unit test — just verify batch management)

$engine->_langfuse_batch([
  { id => '1', type => 'trace-create', body => {} },
  { id => '2', type => 'generation-create', body => {} },
]);

# Override user_agent to capture the request instead of sending
my $captured_request;
{
  no warnings 'redefine';
  local *LWP::UserAgent::request = sub {
    my ($ua, $req) = @_;
    $captured_request = $req;
    return HTTP::Response->new(200, 'OK', ['Content-Type' => 'application/json'], '{"successes":[],"errors":[]}');
  };

  $engine->langfuse_flush;
}

ok($captured_request, 'flush sent an HTTP request');
is($captured_request->method, 'POST', 'flush uses POST');
like($captured_request->uri, qr{/api/public/ingestion$}, 'flush targets ingestion endpoint');
is($captured_request->header('Content-Type'), 'application/json', 'flush sends JSON');

# Verify Basic Auth
my $auth_header = $captured_request->header('Authorization');
like($auth_header, qr/^Basic /, 'flush uses Basic auth');
my $decoded_auth = decode_base64(($auth_header =~ /^Basic (.+)$/)[0]);
is($decoded_auth, 'pk-lf-test123:sk-lf-secret456', 'Basic auth contains correct credentials');

# Verify batch was cleared
is(scalar @{$engine->_langfuse_batch}, 0, 'batch cleared after flush');

# Verify payload
my $sent_body = $json->decode($captured_request->content);
is(scalar @{$sent_body->{batch}}, 2, 'sent batch had 2 events');

# --- flush with empty batch does nothing ---

$captured_request = undef;
{
  no warnings 'redefine';
  local *LWP::UserAgent::request = sub {
    my ($ua, $req) = @_;
    $captured_request = $req;
    return HTTP::Response->new(200, 'OK');
  };

  $engine->langfuse_flush;
}
is($captured_request, undef, 'flush with empty batch sends no request');

done_testing;
