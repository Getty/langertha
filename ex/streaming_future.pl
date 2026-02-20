#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

$|=1;

use Langertha::Engine::OpenAI;

if ($ENV{OPENAI_API_KEY}) {
  warn "Will be using your OPENAI_API_KEY environment variable, which may produce cost.\n";
  sleep 5;
}

my $openai = Langertha::Engine::OpenAI->new(
  api_key => $ENV{OPENAI_API_KEY} || die("Set OPENAI_API_KEY"),
  model => 'gpt-4o-mini',
);

printf "Real-time streaming with Future:\n";
printf "%s\n", "-" x 50;

# Real-time streaming with callback
my $future = $openai->simple_chat_stream_realtime_f(
  sub {
    my ($chunk) = @_;
    printf "[%s]", $chunk->content;
  },
  'Tell me a very short story about a viking in exactly 3 sentences.'
);

my ($content, $chunks) = $future->get;

printf "\n%s\n", "-" x 50;
printf "Total chunks: %d\n", scalar(@$chunks);
printf "Total length: %d characters\n", length($content);
printf "\nFull content:\n%s\n", $content;
