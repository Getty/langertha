#!/usr/bin/env perl
# ABSTRACT: Non-function tool hashes fail loud, never vanish or turn into function tools

use strict;
use warnings;
use Test2::Bundle::More;
use JSON::MaybeXS;
use Langertha::Tool;
use Langertha::Engine::OpenAIResponses;

# Why (karr k210, ADR 0001): a tool hash that is not a function tool used to be
# silently dropped by Tool->from_hash ({type=>'web_search'},
# {google_search=>{}}) or silently turned into a *function* tool
# ({type=>'web_search_20250305', name=>'web_search'}), so the request quietly
# lost its meaning. The door now croaks. Server-side tools are recognised
# explicitly per wire (so the message can name them) until they get their own
# value object (k206). Every other non-function `type` is an unsupported tool
# type: `type` other than `function` does NOT mean "server-side" -- on
# /v1/responses custom, namespace, local_shell, computer_use_preview,
# apply_patch, shell and client tool_search are executed by the client
# (llm-advisor, OpenAI create-response reference, 2026-09-25).
#
# The Responses envelope passes its own native items (flat function, custom,
# namespace, its server-side tools) through verbatim. It used to decide that
# for the WHOLE list from the first item only: a typed item first sent an MCP
# tool unformatted (400); an MCP tool first dropped a built-in and turned
# custom / namespace into function tools. It now decides per item.

my @server = (
  [ responses => { type => 'web_search' } ],
  [ responses => { type => 'web_search_preview_2025_03_11' } ],
  [ responses => { type => 'file_search', vector_store_ids => ['vs'] } ],
  [ responses => { type => 'code_interpreter', container => { type => 'auto' } } ],
  [ responses => { type => 'image_generation' } ],
  [ responses => { type => 'mcp', server_label => 's', server_url => 'https://x' } ],
  [ responses => { type => 'x_search' } ],
  [ responses => { type => 'collections_search' } ],
  [ responses => { type => 'tool_search', execution => 'server' } ],
  [ anthropic => { type => 'web_search_20250305', name => 'web_search', max_uses => 3 } ],
  [ anthropic => { type => 'web_fetch_20250910', name => 'web_fetch' } ],
  [ anthropic => { type => 'code_execution_20250825', name => 'code_execution' } ],
  [ gemini    => { google_search => {} } ],
  [ gemini    => { googleSearch => {} } ],
  [ gemini    => { code_execution => {} } ],
  [ gemini    => { url_context => {} } ],
  [ gemini    => { google_maps => {} } ],
);

my @unsupported = (
  { type => 'custom', name => 'sql', format => { type => 'grammar' } },
  { type => 'namespace', name => 'ns', tools => [] },
  { type => 'local_shell' },
  { type => 'shell', environment => { type => 'local' } },
  { type => 'computer_use_preview', display_width => 1024 },
  { type => 'apply_patch' },
  { type => 'tool_search', execution => 'client' },
  { type => 'programmatic_tool_calling' },
  { type => 'bash_20250124', name => 'bash' },
  { type => 'frobnicate', name => 'x' },
);

my $mcp = { name => 'echo', description => 'Echo', inputSchema => { type => 'object', properties => {} } };

sub croaks_like {
  my ( $code, $re, $label ) = @_;
  my $err;
  eval { $code->(); 1 } or $err = $@;
  like( $err, $re, $label );
}

sub every_door_croaks {
  my ( $hash, $re ) = @_;
  croaks_like( sub { Langertha::Tool->from_hash($hash) }, $re, 'from_hash croaks' );
  for my $order ( [ $hash, $mcp ], [ $mcp, $hash ] ) {
    croaks_like( sub { Langertha::Tool->from_list($order) }, $re, 'from_list croaks on a mixed list' );
    for my $fmt (qw( openai anthropic gemini responses )) {
      croaks_like( sub { Langertha::Tool->format_list( $fmt, $order ) }, $re, "format_list($fmt) croaks" );
    }
  }
}

for my $row (@server) {
  my ( $wire, $hash ) = @$row;
  my ($label) = $hash->{type} // keys %$hash;
  subtest "server-side ($wire): $label" => sub {
    every_door_croaks( $hash, qr/'\Q$label\E' is a server-side tool \($wire\)/ );
  };
}

for my $hash (@unsupported) {
  subtest "unsupported: $hash->{type}" => sub {
    every_door_croaks( $hash, qr/unsupported tool type '\Q$hash->{type}\E'/ );
  };
}

my $json    = JSON::MaybeXS->new->canonical(1)->utf8(1);
my $engine  = Langertha::Engine::OpenAIResponses->new( api_key => 'k', model => 'gpt-5.5-pro' );
my $want_fn = { type => 'function', name => 'echo', description => 'Echo',
                parameters => { type => 'object', properties => {} } };

sub responses_tools {
  my ($tools) = @_;
  my $req = $engine->chat_request( [ { role => 'user', content => 'hi' } ], tools => $tools );
  return $json->decode( $req->content )->{tools};
}

subtest 'Responses envelope: native items verbatim, per item, in both orders' => sub {
  for my $native (
    { type => 'web_search' },
    { type => 'tool_search', execution => 'server' },
    { type => 'custom', name => 'sql', format => { type => 'grammar' } },
    { type => 'namespace', name => 'ns', tools => [] },
  ) {
    is_deeply( responses_tools( [ $native, $mcp ] ), [ $native, $want_fn ],
      "$native->{type} first: verbatim, MCP tool formatted" );
    is_deeply( responses_tools( [ $mcp, $native ] ), [ $want_fn, $native ],
      "$native->{type} second: verbatim, MCP tool formatted" );
  }

  # Every other function-tool form is formatted per item; an already flat
  # Responses function tool stays verbatim wherever it sits.
  my $flat = { type => 'function', name => 'flat', parameters => { type => 'object' } };
  is_deeply( responses_tools( [
    $flat,
    { type => 'function', function => { name => 'echo', description => 'Echo' } },
    Langertha::Tool->new( name => 'echo', description => 'Echo' ),
    { type => 'custom', name => 'echo', description => 'Echo', input_schema => { type => 'object', properties => {} } },
  ] ), [ $flat, $want_fn, $want_fn, $want_fn ],
    'flat function verbatim; nested OpenAI, Tool object, Anthropic custom formatted' );
};

subtest 'Responses envelope: non-native, non-function items croak' => sub {
  croaks_like( sub { responses_tools( [ $mcp, { type => 'local_shell' } ] ) },
    qr/unsupported tool type 'local_shell'/, 'client-executed local_shell croaks' );
  croaks_like( sub { responses_tools( [ { type => 'web_search_20250305', name => 'web_search' }, $mcp ] ) },
    qr/'web_search_20250305' is a server-side tool \(anthropic\)/, 'another wire\'s server tool croaks' );
  croaks_like( sub { responses_tools( [ { google_search => {} } ] ) },
    qr/'google_search' is a server-side tool \(gemini\)/, 'Gemini keyed built-in croaks' );
};

done_testing;
