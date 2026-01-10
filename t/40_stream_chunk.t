#!/usr/bin/env perl
use strict;
use warnings;
use Test2::Bundle::More;

use Langertha::Stream::Chunk;

plan(12);

# Basic chunk creation
my $chunk = Langertha::Stream::Chunk->new(
  content => 'Hello',
);
is($chunk->content, 'Hello', 'content attribute works');
ok(!$chunk->is_final, 'is_final defaults to false');
ok(!$chunk->has_raw, 'has_raw predicate works');
ok(!$chunk->has_finish_reason, 'has_finish_reason predicate works');
ok(!$chunk->has_usage, 'has_usage predicate works');

# Chunk with all attributes
my $full_chunk = Langertha::Stream::Chunk->new(
  content => 'World',
  raw => { test => 1 },
  is_final => 1,
  model => 'gpt-4o',
  finish_reason => 'stop',
  usage => { prompt_tokens => 10, completion_tokens => 20 },
);
is($full_chunk->content, 'World', 'content with all attrs');
ok($full_chunk->is_final, 'is_final set to true');
ok($full_chunk->has_raw, 'has_raw true when set');
is_deeply($full_chunk->raw, { test => 1 }, 'raw data preserved');
is($full_chunk->model, 'gpt-4o', 'model attribute works');
is($full_chunk->finish_reason, 'stop', 'finish_reason works');
is_deeply($full_chunk->usage, { prompt_tokens => 10, completion_tokens => 20 }, 'usage works');

done_testing;
