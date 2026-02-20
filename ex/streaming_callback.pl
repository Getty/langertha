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

printf "Streaming response (synchronous with callback):\n";
printf "%s\n", "-" x 50;

my $chunk_count = 0;

my $full_content = $openai->simple_chat_stream(
  sub {
    my ($chunk) = @_;
    $chunk_count++;
    printf "[%s]", $chunk->content;
  },
  'Tell me a very short story about a viking in exactly 3 sentences.'
);

printf "\n%s\n", "-" x 50;
printf "Total chunks: %d\n", $chunk_count;
printf "Total length: %d characters\n", length($full_content);
printf "\nFull content:\n%s\n", $full_content;
