use strict;
use warnings;
use Test2::V0;
use JSON::MaybeXS;

use Langertha::Usage;
use Langertha::Cost;
use Langertha::UsageRecord;
use Langertha::RateLimit;
use Langertha::Tool;
use Langertha::ToolCall;
use Langertha::ToolChoice;
use Langertha::Response;

# convert_blessed => 1 is the encoder configuration this whole file is about:
# the common consumer setup, and the one Langertha::Plugin::Langfuse uses.
# Every assertion goes through a real encode + decode round trip — a
# can('TO_JSON') check would pass just as happily on a method returning junk.
my $json = JSON::MaybeXS->new( canonical => 1, convert_blessed => 1 );

# Always nest: the failure this fixes is an object buried in a structure the
# caller assembled, not an object handed to the encoder on purpose.
sub roundtrip { return $json->decode( $json->encode( $_[0] ) ) }

# --- Langertha::Usage ---
{
  my $u = Langertha::Usage->new( input_tokens => 100, output_tokens => 50 );
  my $got = roundtrip( { usage => $u } );
  is( $got->{usage},
    { input_tokens => 100, output_tokens => 50, total_tokens => 150 },
    'Usage round-trips as its canonical hash (lazy total_tokens included)' );
}

# --- Langertha::RateLimit: raw stays out of the implicit path ---
{
  my $rl = Langertha::RateLimit->new(
    requests_limit     => 100,
    requests_remaining => 99,
    tokens_limit       => 40000,
    tokens_remaining   => 39500,
    raw                => {
      'x-ratelimit-limit-requests'     => '100',
      'x-ratelimit-remaining-requests' => '99',
    },
  );

  my $got = roundtrip( { rate_limit => $rl } );
  is( $got->{rate_limit},
    {
      requests_limit     => 100,
      requests_remaining => 99,
      tokens_limit       => 40000,
      tokens_remaining   => 39500,
    },
    'RateLimit round-trips its normalized fields' );

  ok( !exists $got->{rate_limit}{raw},
    'RateLimit TO_JSON keeps the provider raw headers out of foreign logs/traces' );

  # The explicit path is unchanged: a caller who asks for raw still gets it.
  ok( exists $rl->to_hash->{raw}, 'to_hash still carries raw (contract unchanged)' );
  is( $rl->to_hash->{raw}{'x-ratelimit-limit-requests'}, '100',
    'to_hash raw content intact' );
}

# --- Langertha::ToolCall ---
{
  my $tc = Langertha::ToolCall->new(
    name      => 'search_files',
    arguments => { pattern => '*.pm', depth => 2 },
    id        => 'call_abc',
  );
  my $got = roundtrip( { tool_call => $tc } );
  is( $got->{tool_call},
    {
      id        => 'call_abc',
      name      => 'search_files',
      arguments => { pattern => '*.pm', depth => 2 },
      synthetic => 0,
    },
    'ToolCall round-trips with nested arguments' );

  my $synth = roundtrip( {
    tool_call => Langertha::ToolCall->new(
      name      => 'extract',
      arguments => { summary => 'hi' },
      synthetic => 1,
    ),
  } );
  is( $synth->{tool_call}{synthetic}, 1,
    'synthetic flag survives the round trip' );
}

# --- Langertha::Tool ---
{
  my $t = Langertha::Tool->new(
    name         => 'list_files',
    description  => 'List files',
    input_schema => { type => 'object', properties => { path => { type => 'string' } } },
  );
  my $got = roundtrip( { tool => $t } );
  is( $got->{tool},
    {
      name         => 'list_files',
      description  => 'List files',
      input_schema => { type => 'object', properties => { path => { type => 'string' } } },
    },
    'Tool round-trips as its canonical hash' );
}

# --- Langertha::Cost ---
{
  my $c = Langertha::Cost->new( input_usd => 0.001, output_usd => 0.002 );
  my $got = roundtrip( { cost => $c } );
  is( $got->{cost},
    {
      input_cost_usd  => 0.001,
      output_cost_usd => 0.002,
      total_cost_usd  => 0.003,
      currency        => 'USD',
    },
    'Cost round-trips as its canonical hash (lazy total included)' );
}

# --- Langertha::UsageRecord ---
{
  my $rec = Langertha::UsageRecord->new(
    usage      => Langertha::Usage->new( input_tokens => 100, output_tokens => 50 ),
    cost       => Langertha::Cost->new( input_usd => 0.001, output_usd => 0.002 ),
    model      => 'gpt-4o-mini',
    provider   => 'openai',
    api_key_id => 'tenant-1',
    tool_calls => 2,
    tool_names => [ 'list_files', 'read_file' ],
  );
  my $got = roundtrip( { record => $rec } );
  is( $got->{record}{model}, 'gpt-4o-mini', 'UsageRecord model' );
  is( $got->{record}{input_tokens}, 100, 'UsageRecord tokens flattened' );
  is( $got->{record}{total_cost_usd} + 0, 0.003, 'UsageRecord cost flattened' );
  is( $got->{record}{tool_names}[1], 'read_file', 'UsageRecord tool names' );
  is( $got->{record}{api_key_id}, 'tenant-1', 'UsageRecord api_key_id' );
}

# --- Langertha::ToolChoice ---
{
  my $named = roundtrip( { tool_choice => Langertha::ToolChoice->specific('extract') } );
  is( $named->{tool_choice}, { type => 'tool', name => 'extract' },
    'ToolChoice round-trips a named tool' );

  my $auto = roundtrip( { tool_choice => Langertha::ToolChoice->auto } );
  is( $auto->{tool_choice}, { type => 'auto' },
    'ToolChoice omits the undef name' );
}

# --- The scenario the change exists for ---
# A consumer writes response metadata to a trace or a JSONL log. tool_calls
# and rate_limit are objects on the declared contract, so they reach the
# encoder without ever announcing themselves as objects; usage joins them once
# it is coerced to a Langertha::Usage. Before TO_JSON this killed the encode
# deep in the call stack, far from where the objects were created.
{
  my $response = Langertha::Response->new(
    content    => 'hello',
    model      => 'claude-sonnet-4-6',
    tool_calls => [ { name => 'ping', arguments => { host => 'example.com' }, id => 'toolu_1' } ],
    rate_limit => Langertha::RateLimit->new(
      requests_remaining => 42,
      raw                => { 'x-ratelimit-remaining-requests' => '42' },
    ),
  );

  my $got = roundtrip( {
    model      => $response->model,
    tool_calls => $response->tool_calls,
    rate_limit => $response->rate_limit,
    usage      => Langertha::Usage->from_response($response),
  } );

  is( $got->{tool_calls}[0]{name}, 'ping',
    'Response->tool_calls encodes through ToolCall TO_JSON' );
  is( $got->{tool_calls}[0]{arguments}{host}, 'example.com',
    'tool call arguments survive the trace payload' );
  is( $got->{rate_limit}{requests_remaining}, 42,
    'Response->rate_limit encodes through RateLimit TO_JSON' );
  ok( !exists $got->{rate_limit}{raw},
    'no provider headers leak into the trace payload' );
  is( $got->{usage}{total_tokens}, 0,
    'Usage encodes through TO_JSON' );
}

# --- Langertha::Response deliberately has NO TO_JSON ---
# Not an oversight. raw is the entire provider payload, probes can hold
# megabytes of tensor data, content is unbounded text — any shape chosen here
# would silently drop most of the object into logs that look complete. Read
# "No TO_JSON — deliberate" in Langertha::Response before adding one; a caller
# serializes the projection it wants (content / usage / tool_calls) instead.
{
  ok( !Langertha::Response->can('TO_JSON'),
    'Langertha::Response has no TO_JSON (deliberate — see its POD)' );

  my $response = Langertha::Response->new(
    content => 'hello',
    raw     => { the => 'whole provider payload' },
  );

  # What a bare Response does here is backend-dependent and deliberately not
  # asserted: Cpanel::JSON::XS falls back to the "" overload and emits the
  # content string, JSON::XS and JSON::PP throw. Both are non-answers. The
  # invariant that must hold on every backend is that no invented metadata
  # shape exists for a consumer to start depending on.
  my $encoded = eval { $json->encode( { response => $response } ) };
  ok( !defined $encoded || !ref( $json->decode($encoded)->{response} ),
    'a Response never encodes as a structured metadata object' );
}

done_testing;
