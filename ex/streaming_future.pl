#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Langertha::Engine::OpenAI;

my $openai = Langertha::Engine::OpenAI->new(
  api_key => $ENV{OPENAI_API_KEY} || die("Set OPENAI_API_KEY"),
  model => 'gpt-4o-mini',
);

print "Real-time streaming with Future:\n";
print "-" x 50, "\n";

# Real-time streaming with callback
my $future = $openai->simple_chat_stream_realtime_f(
  sub {
    my ($chunk) = @_;
    print $chunk->content;
    STDOUT->flush;
  },
  'Tell me a very short story about a viking in exactly 3 sentences.'
);

my ($content, $chunks) = $future->get;

print "\n", "-" x 50, "\n";
print "Total chunks: ", scalar(@$chunks), "\n";
print "Total length: ", length($content), " characters\n";
