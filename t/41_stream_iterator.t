#!/usr/bin/env perl
use strict;
use warnings;
use Test2::Bundle::More;

use Langertha::Stream;
use Langertha::Stream::Chunk;

plan(15);

# Create test chunks
my @chunks = (
  Langertha::Stream::Chunk->new(content => 'Hello'),
  Langertha::Stream::Chunk->new(content => ' '),
  Langertha::Stream::Chunk->new(content => 'World', is_final => 1),
);

# Test iterator creation
my $stream = Langertha::Stream->new(chunks => \@chunks);
ok($stream, 'Stream created');

# Test has_next
ok($stream->has_next, 'has_next returns true at start');

# Test next
my $chunk1 = $stream->next;
is($chunk1->content, 'Hello', 'first chunk correct');
ok($stream->has_next, 'has_next still true');

my $chunk2 = $stream->next;
is($chunk2->content, ' ', 'second chunk correct');

my $chunk3 = $stream->next;
is($chunk3->content, 'World', 'third chunk correct');
ok($chunk3->is_final, 'third chunk is final');

ok(!$stream->has_next, 'has_next false after exhausted');
is($stream->next, undef, 'next returns undef when exhausted');

# Test content
my $stream2 = Langertha::Stream->new(chunks => \@chunks);
is($stream2->content, 'Hello World', 'content returns full text');

# Test reset
$stream2->reset;
ok($stream2->has_next, 'has_next true after reset');
is($stream2->next->content, 'Hello', 'next returns first after reset');

# Test collect
$stream2->reset;
my @collected = $stream2->collect;
is(scalar @collected, 3, 'collect returns all chunks');

# Test each
my $stream3 = Langertha::Stream->new(chunks => \@chunks);
my $result = '';
$stream3->each(sub { $result .= $_[0]->content });
is($result, 'Hello World', 'each iterates all chunks');

# Test empty stream
my $empty = Langertha::Stream->new(chunks => []);
ok(!$empty->has_next, 'empty stream has no next');

done_testing;
