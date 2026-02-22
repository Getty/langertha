#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

$|=1;

use Langertha::Engine::Gemini;

if ($ENV{GEMINI_API_KEY}) {
  warn "Will be using your GEMINI_API_KEY environment variable, which may produce cost.\n";
  sleep 5;
}

my $gemini = Langertha::Engine::Gemini->new(
  api_key => $ENV{GEMINI_API_KEY} || die("Set GEMINI_API_KEY"),
  model => 'gemini-2.5-flash',
  response_size => 1024,
);

# Example 1: Synchronous streaming with callback
printf "Streaming response from Gemini (synchronous with callback):\n";
printf "%s\n", "-" x 50;

my $chunk_count = 0;

my $full_content = $gemini->simple_chat_stream(
  sub {
    my ($chunk) = @_;
    $chunk_count++;
    print $chunk->content;
  },
  'Tell me a very short story about a viking in exactly 3 sentences.'
);

printf "\n%s\n", "-" x 50;
printf "Total chunks: %d\n", $chunk_count;
printf "Total length: %d characters\n", length($full_content);

# Example 2: Real-time streaming with Future
printf "\nReal-time streaming with Future:\n";
printf "%s\n", "-" x 50;

my $future = $gemini->simple_chat_stream_realtime_f(
  sub {
    my ($chunk) = @_;
    print $chunk->content;
  },
  'Write a haiku about Perl programming.'
);

my ($content, $chunks) = $future->get;

printf "\n%s\n", "-" x 50;
printf "Total chunks: %d\n", scalar(@$chunks);
printf "Total length: %d characters\n", length($content);

# Example 3: With system prompt
printf "\nStreaming with system prompt:\n";
printf "%s\n", "-" x 50;

my $gemini_expert = Langertha::Engine::Gemini->new(
  api_key => $ENV{GEMINI_API_KEY},
  model => 'gemini-1.5-pro',
  system_prompt => 'You are a Perl expert. Be concise.',
  temperature => 0.3,
);

$gemini_expert->simple_chat_stream(
  sub { print $_[0]->content },
  'What makes Moose special compared to plain OOP in Perl?'
);

printf "\n%s\n", "-" x 50;
printf "Done!\n";
