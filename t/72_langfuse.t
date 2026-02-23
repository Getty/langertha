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

# --- Clear batch for new tests ---

$engine->_langfuse_batch([]);

# --- Trace with new fields (tags, userId, sessionId, etc.) ---

my $tid2 = $engine->langfuse_trace(
  name        => 'full-trace',
  input       => 'test',
  tags        => ['prod', 'v2'],
  user_id     => 'user-42',
  session_id  => 'sess-abc',
  release     => '1.0.0',
  version     => '3',
  public      => 1,
  environment => 'production',
);
ok($tid2, 'trace with new fields returns ID');

my $full_trace = $engine->_langfuse_batch->[0];
is($full_trace->{type}, 'trace-create', 'full trace type');
is_deeply($full_trace->{body}{tags}, ['prod', 'v2'], 'trace tags set');
is($full_trace->{body}{userId}, 'user-42', 'trace userId set');
is($full_trace->{body}{sessionId}, 'sess-abc', 'trace sessionId set');
is($full_trace->{body}{release}, '1.0.0', 'trace release set');
is($full_trace->{body}{version}, '3', 'trace version set');
ok($full_trace->{body}{public}, 'trace public set to true');
is($full_trace->{body}{environment}, 'production', 'trace environment set');

# Trace with public => 0
my $tid3 = $engine->langfuse_trace(name => 'private-trace', public => 0);
my $priv_trace = $engine->_langfuse_batch->[1];
ok(!$priv_trace->{body}{public}, 'trace public set to false');

# --- Generation with new fields ---

$engine->_langfuse_batch([]);

my $gid2 = $engine->langfuse_generation(
  trace_id              => $tid2,
  name                  => 'gen-full',
  model                 => 'gpt-4o',
  parent_observation_id => 'span-123',
  model_parameters      => { temperature => 0.7, max_tokens => 1000 },
  level                 => 'WARNING',
  status_message        => 'High temperature detected',
  version               => '2',
);
ok($gid2, 'generation with new fields returns ID');

my $full_gen = $engine->_langfuse_batch->[0];
is($full_gen->{body}{parentObservationId}, 'span-123', 'generation parentObservationId set');
is_deeply($full_gen->{body}{modelParameters}, { temperature => 0.7, max_tokens => 1000 },
  'generation modelParameters set');
is($full_gen->{body}{level}, 'WARNING', 'generation level set');
is($full_gen->{body}{statusMessage}, 'High temperature detected', 'generation statusMessage set');
is($full_gen->{body}{version}, '2', 'generation version set');

# --- Create span ---

$engine->_langfuse_batch([]);

my $sid = $engine->langfuse_span(
  trace_id              => $tid2,
  name                  => 'test-span',
  input                 => { query => 'hello' },
  output                => 'done',
  start_time            => '2026-02-22T10:00:00.000Z',
  end_time              => '2026-02-22T10:00:02.000Z',
  parent_observation_id => 'parent-span-1',
  metadata              => { step => 1 },
  level                 => 'DEFAULT',
  status_message        => 'OK',
  version               => '1',
);
ok($sid, 'langfuse_span returns an ID');
like($sid, qr/^[0-9a-f-]+$/, 'span ID looks like a UUID');

my $span_event = $engine->_langfuse_batch->[0];
is($span_event->{type}, 'span-create', 'event type is span-create');
is($span_event->{body}{traceId}, $tid2, 'span linked to trace');
is($span_event->{body}{name}, 'test-span', 'span name set');
is_deeply($span_event->{body}{input}, { query => 'hello' }, 'span input set');
is($span_event->{body}{output}, 'done', 'span output set');
is($span_event->{body}{startTime}, '2026-02-22T10:00:00.000Z', 'span startTime set');
is($span_event->{body}{endTime}, '2026-02-22T10:00:02.000Z', 'span endTime set');
is($span_event->{body}{parentObservationId}, 'parent-span-1', 'span parentObservationId set');
is_deeply($span_event->{body}{metadata}, { step => 1 }, 'span metadata set');
is($span_event->{body}{level}, 'DEFAULT', 'span level set');
is($span_event->{body}{statusMessage}, 'OK', 'span statusMessage set');
is($span_event->{body}{version}, '1', 'span version set');

# --- Span requires trace_id ---

eval { $engine->langfuse_span(name => 'no-trace') };
like($@, qr/requires trace_id/, 'span without trace_id croaks');

# --- Update trace ---

$engine->_langfuse_batch([]);

my $ut_id = $engine->langfuse_update_trace(
  id       => $tid2,
  output   => 'final result',
  metadata => { completed => 1 },
);
is($ut_id, $tid2, 'update_trace returns same ID');

my $ut_event = $engine->_langfuse_batch->[0];
is($ut_event->{type}, 'trace-create', 'update_trace uses trace-create (upsert)');
is($ut_event->{body}{id}, $tid2, 'update_trace body has correct id');
is($ut_event->{body}{output}, 'final result', 'update_trace output set');
is_deeply($ut_event->{body}{metadata}, { completed => 1 }, 'update_trace metadata set');
ok(!exists $ut_event->{body}{name}, 'update_trace omits unset fields');

# --- Update trace requires id ---

eval { $engine->langfuse_update_trace(output => 'test') };
like($@, qr/requires id/, 'update_trace without id croaks');

# --- Update span ---

$engine->_langfuse_batch([]);

my $us_id = $engine->langfuse_update_span(
  id       => $sid,
  end_time => '2026-02-22T10:00:05.000Z',
  output   => { result => 'ok' },
  level    => 'WARNING',
  status_message => 'Slow execution',
);
is($us_id, $sid, 'update_span returns same ID');

my $us_event = $engine->_langfuse_batch->[0];
is($us_event->{type}, 'span-update', 'update_span uses span-update');
is($us_event->{body}{id}, $sid, 'update_span body has correct id');
is($us_event->{body}{endTime}, '2026-02-22T10:00:05.000Z', 'update_span endTime set');
is_deeply($us_event->{body}{output}, { result => 'ok' }, 'update_span output set');
is($us_event->{body}{level}, 'WARNING', 'update_span level set');
is($us_event->{body}{statusMessage}, 'Slow execution', 'update_span statusMessage set');

# --- Update span requires id ---

eval { $engine->langfuse_update_span(end_time => '2026-01-01T00:00:00.000Z') };
like($@, qr/requires id/, 'update_span without id croaks');

# --- Update generation ---

$engine->_langfuse_batch([]);

my $ug_id = $engine->langfuse_update_generation(
  id       => $gid2,
  output   => 'updated response',
  usage    => { input => 50, output => 25, total => 75 },
  end_time => '2026-02-22T10:00:03.000Z',
  level    => 'ERROR',
  status_message        => 'Rate limited',
  completion_start_time => '2026-02-22T10:00:01.000Z',
);
is($ug_id, $gid2, 'update_generation returns same ID');

my $ug_event = $engine->_langfuse_batch->[0];
is($ug_event->{type}, 'generation-update', 'update_generation uses generation-update');
is($ug_event->{body}{id}, $gid2, 'update_generation body has correct id');
is($ug_event->{body}{output}, 'updated response', 'update_generation output set');
is_deeply($ug_event->{body}{usage}, { input => 50, output => 25, total => 75 },
  'update_generation usage set');
is($ug_event->{body}{endTime}, '2026-02-22T10:00:03.000Z', 'update_generation endTime set');
is($ug_event->{body}{level}, 'ERROR', 'update_generation level set');
is($ug_event->{body}{statusMessage}, 'Rate limited', 'update_generation statusMessage set');
is($ug_event->{body}{completionStartTime}, '2026-02-22T10:00:01.000Z',
  'update_generation completionStartTime set');

# --- Update generation requires id ---

eval { $engine->langfuse_update_generation(output => 'test') };
like($@, qr/requires id/, 'update_generation without id croaks');

# --- Disabled engine: new methods return undef ---

my $dis = $engine_no_lf;
is($dis->langfuse_span(trace_id => 'x', name => 'y'), undef, 'span returns undef when disabled');
is($dis->langfuse_update_trace(id => 'x'), undef, 'update_trace returns undef when disabled');
is($dis->langfuse_update_span(id => 'x'), undef, 'update_span returns undef when disabled');
is($dis->langfuse_update_generation(id => 'x'), undef, 'update_generation returns undef when disabled');
is(scalar @{$dis->_langfuse_batch}, 0, 'no events batched on disabled engine');

done_testing;
