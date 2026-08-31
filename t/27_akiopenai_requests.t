#!/usr/bin/env perl
# ABSTRACT: Test AKI.IO OpenAI-compatible response quirks (karr #127)

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;
use HTTP::Response;

use Langertha::Engine::AKIOpenAI;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

my $aki = Langertha::Engine::AKIOpenAI->new(
  api_key => 'testkey',
  model   => 'minimax-m2.5-230b',
);

sub mock_http {
  my ($body) = @_;
  my $http = HTTP::Response->new(200, 'OK');
  $http->content($json->encode($body));
  $http->header('Content-Type' => 'application/json');
  return $http;
}

# --- karr #127.1: AKI ships model reasoning under the bare `reasoning` key,
#     which the shared OpenAI-compatible path (reasoning_content only) drops.
#     AKIOpenAI lifts it onto Response.thinking. ---

my $reasoning_resp = $aki->chat_response(mock_http({
  id      => 'chatcmpl-aki-1',
  model   => 'minimax-m2.5-230b',
  choices => [{
    index         => 0,
    finish_reason => 'stop',
    message       => {
      role      => 'assistant',
      reasoning => 'The user wants me to add 7 and 15.',
      content   => '22',
    },
  }],
}));

is("$reasoning_resp", '22', 'AKIOpenAI content parsed');
ok($reasoning_resp->has_thinking, 'AKIOpenAI lifts the bare reasoning field onto thinking');
is($reasoning_resp->thinking, 'The user wants me to add 7 and 15.', 'thinking carries AKI reasoning');

# The shared reasoning_content spelling still wins where a provider sends it.
my $rc_resp = $aki->chat_response(mock_http({
  id      => 'chatcmpl-aki-2',
  model   => 'minimax-m2.5-230b',
  choices => [{
    index         => 0,
    finish_reason => 'stop',
    message       => {
      role              => 'assistant',
      reasoning_content => 'canonical spelling',
      content           => 'ok',
    },
  }],
}));
is($rc_resp->thinking, 'canonical spelling', 'reasoning_content spelling still surfaces');

# A plain response carries no thinking.
my $plain_resp = $aki->chat_response(mock_http({
  id      => 'chatcmpl-aki-3',
  model   => 'minimax-m2.5-230b',
  choices => [{
    index         => 0,
    finish_reason => 'stop',
    message       => { role => 'assistant', content => 'hello' },
  }],
}));
ok(!$plain_resp->has_thinking, 'plain AKIOpenAI response has no thinking');

done_testing;
