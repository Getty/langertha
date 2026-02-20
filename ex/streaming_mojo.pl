#!/usr/bin/env perl
# Example: Using Langertha's Future-based streaming with Mojolicious
#
# This example shows how to integrate Langertha's Future-based async
# streaming with Mojolicious using Future::Mojo as a bridge.
#
# Required modules:
#   cpanm Mojolicious Future::Mojo IO::Async Net::Async::HTTP

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

printf "Real-time streaming with Future (Mojo-compatible):\n";
printf "%s\n", "-" x 50;

# Get the Future from Langertha
my $future = $openai->simple_chat_stream_realtime_f(
  sub {
    my ($chunk) = @_;
    printf "[%s]", $chunk->content;
  },
  'Tell me a very short story about a viking in exactly 3 sentences.'
);

# Option 1: Simple blocking wait (works anywhere)
my ($content, $chunks) = $future->get;

printf "\n%s\n", "-" x 50;
printf "Total chunks: %d\n", scalar(@$chunks);
printf "Total length: %d characters\n", length($content);

# Option 2: For full Mojo integration, you can use Future::Mojo
# to bridge the IO::Async loop with Mojo::IOLoop:
#
#   use Future::Mojo;
#
#   # Set up the future with callbacks
#   $future->on_done(sub {
#     my ($content, $chunks) = @_;
#     say "Streaming complete!";
#     Mojo::IOLoop->stop;
#   })->on_fail(sub {
#     my ($error) = @_;
#     warn "Error: $error";
#     Mojo::IOLoop->stop;
#   });
#
#   # Run Mojo's event loop
#   # The IO::Async loop will be driven by Future::Mojo
#   Mojo::IOLoop->start;
