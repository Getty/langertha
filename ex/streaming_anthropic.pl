#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

$|=1;

use Langertha::Engine::Anthropic;

if ($ENV{ANTHROPIC_API_KEY}) {
  warn "Will be using your ANTHROPIC_API_KEY environment variable, which may produce cost.\n";
  sleep 5;
}

my $claude = Langertha::Engine::Anthropic->new(
  api_key => $ENV{ANTHROPIC_API_KEY} || die("Set ANTHROPIC_API_KEY"),
  model => 'claude-sonnet-4-6',
  response_size => 1024,
);

# Example 1: Synchronous streaming with callback
printf "Streaming response (synchronous with callback):\n";
printf "%s\n", "-" x 50;

my $chunk_count = 0;

my $full_content = $claude->simple_chat_stream(
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

my $future = $claude->simple_chat_stream_realtime_f(
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

# Example 3: With extended parameters (effort + inference_geo)
printf "\nStreaming with extended parameters:\n";
printf "%s\n", "-" x 50;

my $claude_extended = Langertha::Engine::Anthropic->new(
  api_key => $ENV{ANTHROPIC_API_KEY},
  model => 'claude-sonnet-4-6',
  response_size => 2048,
  effort => 'high',       # More thorough reasoning
  # inference_geo => 'eu', # Uncomment for EU data residency
);

$claude_extended->simple_chat_stream(
  sub { print $_[0]->content },
  'Explain the Moose type system in Perl in 2 sentences.'
);

printf "\n%s\n", "-" x 50;
printf "Done!\n";
