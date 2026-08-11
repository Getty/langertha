#!/usr/bin/env perl
# ABSTRACT: Live integration test for Hetzner Inference engine

use strict;
use warnings;

use Test2::Bundle::More;

BEGIN {
  unless ($ENV{TEST_LANGERTHA_HETZNER_API_KEY}) {
    plan skip_all => 'live skipped: set TEST_LANGERTHA_HETZNER_API_KEY to run';
  }
}

use Langertha::Engine::Hetzner;

my $hetzner = Langertha::Engine::Hetzner->new(
  api_key => $ENV{TEST_LANGERTHA_HETZNER_API_KEY},
);

# --- list_models (static, no HTTP) ---

my $ids = $hetzner->list_models;
is(ref($ids), 'ARRAY', 'list_models returns ArrayRef (static, no HTTP)');
ok(scalar(@$ids) >= 1, 'static model list has at least one entry');
diag "Hetzner static models: @$ids";

# --- simple_chat against the default model (Qwen/Qwen3.6-35B-A3B-FP8) ---

my $chat_model = $ENV{TEST_LANGERTHA_HETZNER_MODEL} || 'Qwen/Qwen3.6-35B-A3B-FP8';
my $chat_hetzner = Langertha::Engine::Hetzner->new(
  api_key => $ENV{TEST_LANGERTHA_HETZNER_API_KEY},
  model   => $chat_model,
);

my $response = eval { $chat_hetzner->simple_chat('Say exactly: Hello Langertha') };
if ($@) {
  if ($@ =~ /429/) {
    diag "Hetzner chat: rate limited (429), skipping";
    pass "skipped due to rate limit";
  } else {
    fail "simple_chat failed: $@";
  }
} else {
  ok(defined $response, 'simple_chat returns a response');
  ok(length($response) > 0, 'simple_chat response is non-empty');
  diag "Hetzner chat response: $response";
}

# --- image understanding (Qwen3.6-35B-A3B-FP8 supports image_url inputs) ---

SKIP: {
  skip 'image understanding: set TEST_LANGERTHA_HETZNER_IMAGE_URL to a public image to run', 1
    unless $ENV{TEST_LANGERTHA_HETZNER_IMAGE_URL};

  require Langertha::Content::Image;
  my $img = Langertha::Content::Image->from_url($ENV{TEST_LANGERTHA_HETZNER_IMAGE_URL});
  my $resp = eval {
    $chat_hetzner->simple_chat({
      role    => 'user',
      content => [ 'Describe this image in one short sentence.', $img ],
    });
  };
  if ($@) {
    if ($@ =~ /429/) {
      diag "Hetzner image: rate limited (429), skipping";
      pass "skipped due to rate limit";
    } else {
      fail "image understanding failed: $@";
    }
  } else {
    ok(defined $resp && length($resp) > 0, 'image understanding returns a non-empty response');
    diag "Hetzner image response: $resp";
  }
}

# --- tool calling (advertised but docs do not explicitly confirm; verify live) ---

SKIP: {
  skip 'tool calling: set TEST_LANGERTHA_HETZNER_TEST_TOOLS=1 to exercise native tools', 1
    unless $ENV{TEST_LANGERTHA_HETZNER_TEST_TOOLS};

  require Future::AsyncAwait;
  require MCP::Server;
  require Net::Async::MCP;
  require IO::Async::Loop;

  my $server = MCP::Server->new(name => 'hetzner-tools', version => '1.0');
  $server->tool(
    name        => 'echo',
    description => 'Echo back the input text',
    input_schema => {
      type       => 'object',
      properties => { message => { type => 'string' } },
      required   => ['message'],
    },
    code => sub {
      my ($self, $args) = @_;
      return $self->text_result($args->{message} // '');
    },
  );

  my $loop = IO::Async::Loop->new;
  my $mcp  = Net::Async::MCP->new(server => $server);
  $loop->add($mcp);

  async sub test_tools {
    await $mcp->initialize;

    my $engine = Langertha::Engine::Hetzner->new(
      api_key     => $ENV{TEST_LANGERTHA_HETZNER_API_KEY},
      model       => $chat_model,
      mcp_servers => [$mcp],
    );

    my $r = eval {
      await $engine->chat_with_tools_f('Use the echo tool to say "ping".');
    };
    if ($@) {
      if ($@ =~ /429/) {
        diag "Hetzner tools: rate limited (429), skipping";
        pass "skipped due to rate limit";
      } else {
        fail "chat_with_tools_f failed: $@";
      }
    } else {
      ok(defined $r && length($r) > 0, 'chat_with_tools_f returned a non-empty response');
      diag "Hetzner tools response: $r";
    }
  }

  test_tools()->get;
}

done_testing;
