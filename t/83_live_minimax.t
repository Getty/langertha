#!/usr/bin/env perl
# ABSTRACT: Live integration test for MiniMax engine and Coding Plan web search

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;

BEGIN {
  unless ($ENV{TEST_LANGERTHA_MINIMAX_API_KEY}) {
    plan skip_all => 'Set TEST_LANGERTHA_MINIMAX_API_KEY to run this test';
  }
  eval {
    require IO::Async::Loop;
    require Future::AsyncAwait;
    require Net::Async::MCP;
    require MCP::Server;
    require MCP::Tool;
    1;
  } or plan skip_all => 'Requires IO::Async, Net::Async::MCP, and MCP modules';
}

use IO::Async::Loop;
use Future::AsyncAwait;
use Net::Async::MCP;
use MCP::Server;
use Langertha::Engine::MiniMax;
use Langertha::Raider;

my $json = JSON::MaybeXS->new(utf8 => 1);

# --- simple_chat ---

my $minimax = Langertha::Engine::MiniMax->new(
  api_key => $ENV{TEST_LANGERTHA_MINIMAX_API_KEY},
);

my $response = $minimax->simple_chat('Say exactly: Hello Langertha');
ok(defined $response, 'simple_chat returns a response');
ok(length $response > 0, 'simple_chat response is non-empty');
diag "MiniMax chat response: $response";

# --- list_models ---
# MiniMax does not provide a /v1/models endpoint, so list_models is expected
# to fail. Verify it throws rather than silently returning garbage.

eval { $minimax->list_models };
ok($@, 'list_models fails (MiniMax has no /v1/models endpoint)');
diag "list_models error (expected): $@";

# --- Coding Plan web search via Raider ---

SKIP: {
  skip 'Set TEST_LANGERTHA_MINIMAX_WEBSEARCH=1 to test Coding Plan web search', 6
    unless $ENV{TEST_LANGERTHA_MINIMAX_WEBSEARCH};

  my $server = MCP::Server->new(name => 'minimax-search', version => '1.0');

  # Register web_search tool that calls MiniMax Coding Plan search API
  $server->tool(
    name => 'web_search',
    description => 'Search the web using MiniMax Coding Plan API. Returns titles, links, and snippets.',
    input_schema => {
      type => 'object',
      properties => {
        query => { type => 'string', description => 'Search query (3-5 keywords for best results)' },
      },
      required => ['query'],
    },
    code => sub {
      my ($self, $args) = @_;
      my $query = $args->{query} or return $self->text_result('Error: query required');

      # Call MiniMax Coding Plan search endpoint
      require HTTP::Request;
      require LWP::UserAgent;

      my $ua = LWP::UserAgent->new(timeout => 30);
      my $req = HTTP::Request->new(
        POST => 'https://api.minimax.io/v1/coding_plan/search',
      );
      $req->header('Authorization' => 'Bearer ' . $ENV{TEST_LANGERTHA_MINIMAX_API_KEY});
      $req->header('Content-Type' => 'application/json');
      $req->content($json->encode({ q => $query }));

      my $resp = $ua->request($req);
      unless ($resp->is_success) {
        return $self->text_result('Search API error: ' . $resp->status_line);
      }

      my $data = $json->decode($resp->decoded_content);

      # Check for API error
      my $base_resp = $data->{base_resp} || {};
      if (($base_resp->{status_code} || 0) != 0) {
        return $self->text_result('Search API error: ' . ($base_resp->{status_msg} || 'unknown'));
      }

      # Format organic results
      my @results;
      for my $item (@{$data->{organic} || []}) {
        push @results, sprintf("[%s](%s)\n%s", $item->{title} || '', $item->{link} || '', $item->{snippet} || '');
      }

      return $self->text_result(join("\n\n", @results) || 'No results found.');
    },
  );

  my $loop = IO::Async::Loop->new;
  my $mcp = Net::Async::MCP->new(server => $server);
  $loop->add($mcp);

  async sub test_raider_websearch {
    await $mcp->initialize;

    my $tools = await $mcp->list_tools;
    is(scalar @$tools, 1, 'MCP server has web_search tool');

    my $engine = Langertha::Engine::MiniMax->new(
      api_key     => $ENV{TEST_LANGERTHA_MINIMAX_API_KEY},
      mcp_servers => [$mcp],
    );

    my $raider = Langertha::Raider->new(
      engine  => $engine,
      mission => 'You are a coding research assistant. Use web_search to find information. Be concise.',
    );

    # Raid: search for something coding-related
    my $r1 = await $raider->raid_f(
      'Search for "Perl MCP Model Context Protocol" and summarize what you find in 2-3 sentences.'
    );
    diag "Raider web search response: $r1";
    ok(defined $r1 && length $r1 > 0, 'Raider web search returned a response');
    cmp_ok($raider->metrics->{tool_calls}, '>=', 1, 'Raider made at least 1 web search tool call');

    # Check session_history captured everything
    my @sh = @{$raider->session_history};
    cmp_ok(scalar @sh, '>=', 3, 'session_history has at least 3 entries (user + tool msgs + assistant)');

    # Verify history for follow-up
    my $history_count = scalar @{$raider->history};
    cmp_ok($history_count, '>=', 2, 'working history has at least 2 messages');

    diag "Metrics: raids=${\$raider->metrics->{raids}}, tool_calls=${\$raider->metrics->{tool_calls}}, time=${\sprintf('%.0f', $raider->metrics->{time_ms})}ms";
  }

  test_raider_websearch()->get;
}

done_testing;
