#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Langertha::Engine::Ollama;

my $ollama = Langertha::Engine::Ollama->new(
  url => $ENV{OLLAMA_URL} || 'http://localhost:11434',
  model => $ENV{OLLAMA_MODEL} || 'llama3.1',
);

print "Streaming with iterator:\n";
print "-" x 40, "\n";

my $stream = $ollama->simple_chat_stream_iterator(
  'What is Perl? Answer in exactly 2 sentences.'
);

while (my $chunk = $stream->next) {
  print $chunk->content;
  STDOUT->flush;

  if ($chunk->is_final && $chunk->has_usage) {
    my $usage = $chunk->usage;
    print "\n", "-" x 40, "\n";
    print "Prompt tokens: ", ($usage->{prompt_tokens} // 'N/A'), "\n";
    print "Completion tokens: ", ($usage->{completion_tokens} // 'N/A'), "\n";
  }
}

print "\n";
