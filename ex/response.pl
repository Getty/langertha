#!/usr/bin/env perl
# ABSTRACT: Response metadata — see token usage, model, timing from every engine
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

$|=1;

# Pick an engine based on which API key is available
my ($engine_name, $engine);

if ($ENV{ANTHROPIC_API_KEY}) {
  require Langertha::Engine::Anthropic;
  $engine = Langertha::Engine::Anthropic->new(
    api_key => $ENV{ANTHROPIC_API_KEY},
    model   => 'claude-haiku-4-5-20251001',
  );
  $engine_name = 'Anthropic';
}
elsif ($ENV{OPENAI_API_KEY}) {
  require Langertha::Engine::OpenAI;
  $engine = Langertha::Engine::OpenAI->new(
    api_key => $ENV{OPENAI_API_KEY},
    model   => 'gpt-4o-mini',
  );
  $engine_name = 'OpenAI';
}
elsif ($ENV{GEMINI_API_KEY}) {
  require Langertha::Engine::Gemini;
  $engine = Langertha::Engine::Gemini->new(
    api_key => $ENV{GEMINI_API_KEY},
    model   => 'gemini-2.5-flash',
  );
  $engine_name = 'Gemini';
}
elsif ($ENV{DEEPSEEK_API_KEY}) {
  require Langertha::Engine::DeepSeek;
  $engine = Langertha::Engine::DeepSeek->new(
    api_key => $ENV{DEEPSEEK_API_KEY},
    model   => 'deepseek-chat',
  );
  $engine_name = 'DeepSeek';
}
else {
  die "Set one of: ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, DEEPSEEK_API_KEY\n";
}

printf "Engine: %s (%s)\n", $engine_name, $engine->chat_model;
printf "%s\n\n", "=" x 60;

# --- simple_chat now returns a Langertha::Response ---

my $response = $engine->simple_chat(
  'Write a haiku about Perl programming. Just the haiku, nothing else.'
);

# Backward compatible: stringifies to content
printf "Response:\n%s\n\n", $response;

# But now we have metadata!
printf "%s\n", "-" x 60;
printf "%-20s %s\n", "Class:", ref $response;
printf "%-20s %s\n", "Model:", $response->model // '(not provided)';
printf "%-20s %s\n", "Response ID:", $response->id // '(not provided)';
printf "%-20s %s\n", "Finish reason:", $response->finish_reason // '(not provided)';
printf "%-20s %s\n", "Created:", $response->has_created
  ? scalar(localtime($response->created)) : '(not provided)';

printf "\n";
printf "Token Usage:\n";
printf "  %-18s %s\n", "Prompt tokens:", $response->prompt_tokens // '(not available)';
printf "  %-18s %s\n", "Completion tokens:", $response->completion_tokens // '(not available)';
printf "  %-18s %s\n", "Total tokens:", $response->total_tokens // '(not available)';

if ($response->has_timing) {
  printf "\n";
  printf "Timing:\n";
  for my $k (sort keys %{$response->timing}) {
    printf "  %-24s %s\n", "$k:", $response->timing->{$k};
  }
}

printf "\n%s\n", "-" x 60;

# --- Show that existing code still works ---

printf "\nBackward compatibility: \"%s\" eq \"%s\" ? %s\n",
  substr("$response", 0, 30).'...', substr($response->content, 0, 30).'...',
  ("$response" eq $response->content) ? 'YES' : 'NO';

# --- Multiple calls show different metadata ---

printf "\n%s\n", "=" x 60;
printf "Second call (different prompt):\n\n";

my $r2 = $engine->simple_chat('What is 2+2? Answer with just the number.');
printf "Response: %s\n", $r2;
printf "Model: %s | Tokens: %s prompt, %s completion, %s total\n",
  $r2->model // '?',
  $r2->prompt_tokens // '?',
  $r2->completion_tokens // '?',
  $r2->total_tokens // '?';
