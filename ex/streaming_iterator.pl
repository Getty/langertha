#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

$|=1;

use Langertha::Engine::Ollama;

my $ollama = Langertha::Engine::Ollama->new(
  url => $ENV{OLLAMA_URL} || 'http://localhost:11434',
  model => $ENV{OLLAMA_MODEL} || 'llama3.1',
);

printf "Streaming with iterator (Ollama):\n";
printf "%s\n", "-" x 50;

my $stream = $ollama->simple_chat_stream_iterator(
  'What is Perl? Answer in exactly 2 sentences.'
);

my $chunk_count = 0;
my $full_content = '';

while (my $chunk = $stream->next) {
  $chunk_count++;
  $full_content .= $chunk->content;
  printf "[%s]", $chunk->content;
}

printf "\n%s\n", "-" x 50;
printf "Total chunks: %d\n", $chunk_count;
printf "Total length: %d characters\n", length($full_content);
printf "\nFull content:\n%s\n", $full_content;
