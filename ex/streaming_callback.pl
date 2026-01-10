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

print "Streaming response:\n";
print "-" x 40, "\n";

my $full_content = $openai->simple_chat_stream(
  sub {
    my ($chunk) = @_;
    print $chunk->content;
    STDOUT->flush;
  },
  'Tell me a very short story about a viking in exactly 3 sentences.'
);

print "\n", "-" x 40, "\n";
print "Full content length: ", length($full_content), " characters\n";
