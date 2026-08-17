#!/usr/bin/env perl
# ABSTRACT: Unit tests for Raider self-tools, inline tools, and MCP catalog

use strict;
use warnings;

use Test2::Bundle::More;

use Langertha::Raider;
use Langertha::Raider::Result;

# --- Helper: minimal mock engine that satisfies Raider's needs ---

{
  package MockEngine;
  use Moose;
  with 'Langertha::Role::Tools';

  has chat_model => (is => 'ro', default => 'mock-model');
  has '+mcp_servers' => (default => sub { [] });

  sub format_tools {
    my ($self, $tools) = @_;
    # Return in MCP format (same as input for mock)
    return $tools;
  }

  sub response_tool_calls { return [] }
  sub extract_tool_call { return ($_[1]->{name}, $_[1]->{input}) }
  sub format_tool_results { return () }
  sub response_text_content { return 'mock response' }
  sub think_tag_filter { 0 }

  __PACKAGE__->meta->make_immutable;
}

# --- Test: self-tool definitions ---

subtest 'self-tool definitions - all enabled' => sub {
  my $raider = Langertha::Raider->new(
    engine    => MockEngine->new,
    raider_mcp => 1,
  );

  my $defs = $raider->_self_tool_definitions;
  is(scalar @$defs, 7, '7 self-tools when all enabled');

  my %names = map { $_->{name} => 1 } @$defs;
  ok($names{raider_ask_user}, 'raider_ask_user defined');
  ok($names{raider_wait}, 'raider_wait defined');
  ok($names{raider_wait_for}, 'raider_wait_for defined');
  ok($names{raider_pause}, 'raider_pause defined');
  ok($names{raider_abort}, 'raider_abort defined');
  ok($names{raider_session_history}, 'raider_session_history defined');
  ok($names{raider_manage_mcps}, 'raider_manage_mcps defined');

  # Verify inputSchema is in MCP format (camelCase)
  for my $tool (@$defs) {
    ok(exists $tool->{inputSchema}, "tool $tool->{name} has inputSchema");
    is($tool->{inputSchema}{type}, 'object', "tool $tool->{name} inputSchema is object");
  }
};

subtest 'self-tool definitions - selective' => sub {
  my $raider = Langertha::Raider->new(
    engine    => MockEngine->new,
    raider_mcp => { ask_user => 1, abort => 1 },
  );

  my $defs = $raider->_self_tool_definitions;
  is(scalar @$defs, 2, '2 self-tools when selective');

  my %names = map { $_->{name} => 1 } @$defs;
  ok($names{raider_ask_user}, 'raider_ask_user enabled');
  ok($names{raider_abort}, 'raider_abort enabled');
  ok(!$names{raider_wait}, 'raider_wait not enabled');
};

subtest 'self-tool definitions - disabled' => sub {
  my $raider = Langertha::Raider->new(
    engine => MockEngine->new,
  );

  my $defs = $raider->_self_tool_definitions;
  is(scalar @$defs, 0, 'no self-tools when raider_mcp not set');
};

# --- Test: _execute_self_tool ---

subtest 'execute ask_user with callback' => sub {
  my $raider = Langertha::Raider->new(
    engine     => MockEngine->new,
    raider_mcp => 1,
    on_ask_user => sub {
      my ($question, $options) = @_;
      return "I choose red";
    },
  );

  my $result = $raider->_execute_self_tool('raider_ask_user', {
    question => 'What color?',
    options  => ['red', 'blue'],
  });

  is($result->{type}, 'result', 'ask_user with callback returns result');
  is($result->{content}[0]{text}, 'I choose red', 'callback answer used');
};

subtest 'execute ask_user without callback' => sub {
  my $raider = Langertha::Raider->new(
    engine     => MockEngine->new,
    raider_mcp => 1,
  );

  my $result = $raider->_execute_self_tool('raider_ask_user', {
    question => 'What color?',
    options  => ['red', 'blue'],
  });

  is($result->{type}, 'question', 'ask_user without callback returns question');
  is($result->{question}, 'What color?', 'question text preserved');
  is_deeply($result->{options}, ['red', 'blue'], 'options preserved');
};

subtest 'execute abort' => sub {
  my $raider = Langertha::Raider->new(
    engine     => MockEngine->new,
    raider_mcp => 1,
  );

  my $result = $raider->_execute_self_tool('raider_abort', {
    reason => 'Cannot continue',
  });

  is($result->{type}, 'abort', 'abort returns abort type');
  is($result->{reason}, 'Cannot continue', 'abort reason preserved');
};

subtest 'execute pause with callback' => sub {
  my $paused_reason;
  my $raider = Langertha::Raider->new(
    engine     => MockEngine->new,
    raider_mcp => 1,
    on_pause   => sub { $paused_reason = $_[0] },
  );

  my $result = $raider->_execute_self_tool('raider_pause', {
    reason => 'Taking a break',
  });

  is($result->{type}, 'result', 'pause with callback returns result');
  is($paused_reason, 'Taking a break', 'on_pause callback invoked');
};

subtest 'execute pause without callback' => sub {
  my $raider = Langertha::Raider->new(
    engine     => MockEngine->new,
    raider_mcp => 1,
  );

  my $result = $raider->_execute_self_tool('raider_pause', {
    reason => 'Thinking',
  });

  is($result->{type}, 'pause', 'pause without callback returns pause');
  is($result->{reason}, 'Thinking', 'reason preserved');
};

subtest 'execute wait' => sub {
  my $raider = Langertha::Raider->new(
    engine     => MockEngine->new,
    raider_mcp => 1,
  );

  my $result = $raider->_execute_self_tool('raider_wait', {
    seconds => 5,
    reason  => 'Rate limiting',
  });

  is($result->{type}, 'wait', 'wait returns wait type');
  is($result->{seconds}, 5, 'seconds preserved');
};

subtest 'execute wait_for with callback' => sub {
  my $raider = Langertha::Raider->new(
    engine      => MockEngine->new,
    raider_mcp  => 1,
    on_wait_for => sub {
      my ($condition, $args) = @_;
      return "Condition '$condition' met";
    },
  );

  my $result = $raider->_execute_self_tool('raider_wait_for', {
    condition => 'file_exists',
    args      => { path => '/tmp/test' },
  });

  is($result->{type}, 'result', 'wait_for returns result');
  like($result->{content}[0]{text}, qr/file_exists/, 'condition included');
};

subtest 'execute wait_for without callback dies' => sub {
  my $raider = Langertha::Raider->new(
    engine     => MockEngine->new,
    raider_mcp => 1,
  );

  eval {
    $raider->_execute_self_tool('raider_wait_for', {
      condition => 'something',
    });
  };
  like($@, qr/No on_wait_for callback/, 'dies without callback');
};

# --- Test: session history query ---

subtest 'session history query' => sub {
  my $raider = Langertha::Raider->new(
    engine     => MockEngine->new,
    raider_mcp => 1,
  );

  # Manually populate session history
  push @{$raider->session_history}, (
    { role => 'user', content => 'Hello world' },
    { role => 'assistant', content => 'Hi there' },
    { role => 'user', content => 'Tell me about Perl' },
    { role => 'assistant', content => 'Perl is a programming language' },
    { role => 'user', content => 'And about Python' },
  );

  my $result = $raider->_execute_self_tool('raider_session_history', {});
  is($result->{type}, 'result', 'returns result');
  like($result->{content}[0]{text}, qr/Hello world/, 'contains first message');
  like($result->{content}[0]{text}, qr/Perl/, 'contains Perl message');

  # Test text filter
  $result = $raider->_execute_self_tool('raider_session_history', {
    query => 'Perl',
  });
  like($result->{content}[0]{text}, qr/Perl/, 'query filter works');
  unlike($result->{content}[0]{text}, qr/Hello world/, 'query filter excludes non-matching');

  # Test last_n
  $result = $raider->_execute_self_tool('raider_session_history', {
    last_n => 2,
  });
  like($result->{content}[0]{text}, qr/Perl is a programming/, 'last_n returns recent');
  like($result->{content}[0]{text}, qr/Python/, 'last_n returns most recent');
};

# --- Test: session history rendering across wire formats (karr #96) ---

# session_history holds whatever the engine's format_tool_results() put on the
# wire, so the element shape follows tool_wire_format. Only openai/ollama/hermes
# hand every element a {role} plus a plain-string {content}; anthropic content
# is an ArrayRef of blocks, gemini keeps blocks under {parts}, and responses
# items have no {role} at all. Rendering must stay readable for all of them and
# must not emit uninitialized warnings.

{
  package MockToolServer;
  use Moose;
  has tools => (is => 'ro', default => sub { {} });
  sub tool {
    my ( $self, %args ) = @_;
    $self->tools->{$args{name}} = \%args;
    return;
  }
  __PACKAGE__->meta->make_immutable;
}

{
  package MockToolHandle;
  use Moose;
  sub text_result {
    my ( $self, $text ) = @_;
    return { content => [ { type => 'text', text => $text } ] };
  }
  __PACKAGE__->meta->make_immutable;
}

sub mixed_wire_history {
  return (
    # --- anthropic: content is an ArrayRef of blocks ---
    { role => 'user', content => 'What is the weather in Berlin?' },
    { role => 'assistant', content => [
      { type => 'text', text => 'Let me check the weather.' },
      { type => 'tool_use', id => 'toolu_01', name => 'get_weather',
        input => { city => 'Berlin' } },
    ] },
    { role => 'user', content => [
      { type => 'tool_result', tool_use_id => 'toolu_01',
        content => [ { type => 'text', text => 'Berlin: sunny, 22C' } ] },
    ] },
    # --- responses: envelope items, discriminated by {type}, no {role} ---
    { type => 'reasoning', id => 'rs_1',
      summary => [ { type => 'summary_text', text => 'Need the weather tool.' } ] },
    { type => 'message', role => 'assistant', status => 'completed',
      content => [ { type => 'output_text', text => 'Checking Hamburg now.' } ] },
    { type => 'function_call', call_id => 'call_1', name => 'get_weather',
      arguments => '{"city":"Hamburg"}' },
    { type => 'function_call_output', call_id => 'call_1',
      output => '[{"text":"Hamburg: rainy, 14C","type":"text"}]' },
    # --- openai: assistant echo has content => undef when it only calls tools ---
    { role => 'assistant', content => undef, tool_calls => [
      { id => 'call_2', type => 'function',
        function => { name => 'get_time', arguments => '{"tz":"CET"}' } },
    ] },
    { role => 'tool', tool_call_id => 'call_2',
      content => '[{"type":"text","text":"14:05"}]' },
    # --- gemini: blocks live under {parts}, there is no {content} at all ---
    { role => 'model', parts => [
      { text => 'One moment.' },
      { functionCall => { name => 'get_weather', args => { city => 'Kiel' } } },
    ] },
    { role => 'user', parts => [
      { functionResponse => { name => 'get_weather',
        response => { result => 'Kiel: windy, 17C' } } },
    ] },
  );
}

subtest 'session history rendering across wire formats' => sub {
  my $raider = Langertha::Raider->new(
    engine     => MockEngine->new,
    raider_mcp => 1,
  );
  push @{$raider->session_history}, mixed_wire_history();

  my @warnings;
  my $text;
  {
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    $text = $raider->_query_session_history({});
  }

  is(scalar @warnings, 0, 'no warnings while rendering mixed-wire history')
    or diag("warnings: @warnings");

  unlike($text, qr/ARRAY\(0x/, 'ArrayRef content is flattened, not stringified');
  unlike($text, qr/HASH\(0x/, 'HashRef payloads are flattened, not stringified');
  unlike($text, qr/^\[[^\]]*\]\s*$/m, 'no history element renders as a bare label');

  # anthropic
  like($text, qr/\[assistant\] Let me check the weather\./, 'anthropic text block rendered');
  like($text, qr/get_weather.*Berlin/, 'anthropic tool_use is visible with its arguments');
  like($text, qr/Berlin: sunny, 22C/, 'anthropic tool_result content flattened to text');

  # responses
  like($text, qr/\[reasoning\] Need the weather tool\./, 'responses reasoning summary rendered');
  like($text, qr/\[assistant\] Checking Hamburg now\./, 'responses message item uses its role');
  like($text, qr/\[function_call\] .*get_weather.*Hamburg/, 'responses function_call labelled by type');
  like($text, qr/\[function_call_output\] .*Hamburg: rainy, 14C/,
    'responses function_call_output labelled by type and carries its output');

  # openai
  like($text, qr/\[assistant\] .*get_time.*CET/, 'openai tool-only assistant echo shows the call');
  like($text, qr/14:05/, 'openai tool result content kept');

  # gemini
  like($text, qr/\[model\] One moment\./, 'gemini text part rendered');
  like($text, qr/get_weather.*Kiel/, 'gemini functionCall part is visible');
  like($text, qr/Kiel: windy, 17C/, 'gemini functionResponse flattened');
};

subtest 'session history query filters on rendered payload' => sub {
  my $raider = Langertha::Raider->new(
    engine     => MockEngine->new,
    raider_mcp => 1,
  );
  push @{$raider->session_history}, mixed_wire_history();

  my @warnings;
  my ( $hamburg, $kiel );
  {
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    $hamburg = $raider->_query_session_history({ query => 'Hamburg' });
    $kiel    = $raider->_query_session_history({ query => 'Kiel: windy' });
  }
  is(scalar @warnings, 0, 'no warnings while filtering mixed-wire history')
    or diag("warnings: @warnings");

  like($hamburg, qr/Hamburg/, 'filter matches inside responses items');
  unlike($hamburg, qr/Berlin/, 'filter excludes non-matching elements');
  like($kiel, qr/Kiel: windy, 17C/, 'filter reaches into gemini functionResponse text');
};

subtest 'register_session_history_tool renders identically' => sub {
  my $raider = Langertha::Raider->new(
    engine     => MockEngine->new,
    raider_mcp => 1,
  );
  push @{$raider->session_history}, mixed_wire_history();

  my $server = MockToolServer->new;
  $raider->register_session_history_tool($server);
  my $registered = $server->tools->{session_history};
  ok($registered, 'session_history tool registered');

  my @warnings;
  my $result;
  {
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    $result = $registered->{code}->(MockToolHandle->new, {});
  }
  is(scalar @warnings, 0, 'no warnings from the MCP-registered renderer')
    or diag("warnings: @warnings");

  is($result->{content}[0]{text}, $raider->_query_session_history({}),
    'both history readers share one renderer');
};

subtest 'empty session history' => sub {
  my $raider = Langertha::Raider->new(
    engine     => MockEngine->new,
    raider_mcp => 1,
  );
  is($raider->_query_session_history({}), 'No messages in session history.',
    'empty history keeps its placeholder');
};

# --- Test: MCP catalog management ---

subtest 'manage MCPs' => sub {
  my $raider = Langertha::Raider->new(
    engine      => MockEngine->new,
    raider_mcp  => 1,
    mcp_catalog => {
      database => { server => 'mock_db', description => 'Database tools', auto => 1 },
      email    => { server => 'mock_email', description => 'Email tools' },
    },
  );

  # Auto-activated MCPs
  ok(exists $raider->_active_catalog_mcps->{database}, 'database auto-activated');
  ok(!exists $raider->_active_catalog_mcps->{email}, 'email not auto-activated');

  # List
  my $result = $raider->_execute_self_tool('raider_manage_mcps', {
    action => 'list',
  });
  like($result->{content}[0]{text}, qr/database \[ACTIVE\]/, 'list shows active');
  like($result->{content}[0]{text}, qr/email \[inactive\]/, 'list shows inactive');

  # Activate
  $result = $raider->_execute_self_tool('raider_manage_mcps', {
    action => 'activate',
    name   => 'email',
  });
  like($result->{content}[0]{text}, qr/Activated/, 'activate succeeds');
  ok(exists $raider->_active_catalog_mcps->{email}, 'email now active');
  ok($raider->_tools_dirty, 'tools marked dirty after activate');
  $raider->_tools_dirty(0);

  # Deactivate
  $result = $raider->_execute_self_tool('raider_manage_mcps', {
    action => 'deactivate',
    name   => 'database',
  });
  like($result->{content}[0]{text}, qr/Deactivated/, 'deactivate succeeds');
  ok(!exists $raider->_active_catalog_mcps->{database}, 'database now inactive');
  ok($raider->_tools_dirty, 'tools marked dirty after deactivate');

  # Error cases
  $result = $raider->_execute_self_tool('raider_manage_mcps', {
    action => 'activate',
    name   => 'nonexistent',
  });
  like($result->{content}[0]{text}, qr/not found/, 'activate non-existent fails gracefully');
};

# --- Test: inline tools attribute ---

subtest 'inline tools configuration' => sub {
  my $raider = Langertha::Raider->new(
    engine => MockEngine->new,
    tools  => [{
      name         => 'greet',
      description  => 'Greet someone',
      input_schema => {
        type       => 'object',
        properties => { name => { type => 'string' } },
      },
      code => sub { $_[0]->text_result("Hello $_[1]->{name}!") },
    }],
  );

  is(scalar @{$raider->tools}, 1, 'inline tools stored');
  is($raider->tools->[0]{name}, 'greet', 'tool name preserved');
};

# --- Test: continuation state ---

subtest 'continuation management' => sub {
  my $raider = Langertha::Raider->new(
    engine     => MockEngine->new,
    raider_mcp => 1,
  );

  ok(!$raider->has_continuation, 'no continuation initially');

  $raider->_continuation({ test => 'data' });
  ok($raider->has_continuation, 'has continuation after set');

  $raider->clear_continuation;
  ok(!$raider->has_continuation, 'no continuation after clear');
};

# --- Test: cosine similarity ---

subtest 'cosine similarity' => sub {
  # Identical vectors
  my $sim = Langertha::Raider::_cosine_similarity([1, 0, 0], [1, 0, 0]);
  cmp_ok(abs($sim - 1.0), '<', 0.001, 'identical vectors = 1.0');

  # Orthogonal vectors
  $sim = Langertha::Raider::_cosine_similarity([1, 0], [0, 1]);
  cmp_ok(abs($sim), '<', 0.001, 'orthogonal vectors = 0.0');

  # Similar vectors
  $sim = Langertha::Raider::_cosine_similarity([1, 1], [1, 0.9]);
  cmp_ok($sim, '>', 0.9, 'similar vectors have high similarity');

  # Zero vector
  $sim = Langertha::Raider::_cosine_similarity([0, 0], [1, 1]);
  is($sim, 0, 'zero vector returns 0');
};

done_testing;
