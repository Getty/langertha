#!/usr/bin/env perl
# ABSTRACT: Langfuse observability — trace LLM calls to Langfuse dashboard
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

$|=1;

# --- Langfuse is built into every engine ---
#
# Just pass langfuse_public_key + langfuse_secret_key and it's on.
# Without keys, nothing happens — zero overhead.
#
# Works with: OpenAI, Anthropic, Gemini, DeepSeek, Ollama, Groq, Mistral, ...
#
# Quick start with Kubernetes:
#   kubectl apply -f ex/langfuse-k8s.yaml
#   kubectl -n langfuse port-forward svc/langfuse-web 3000:3000 &
#   export LANGFUSE_PUBLIC_KEY=pk-lf-langertha
#   export LANGFUSE_SECRET_KEY=sk-lf-langertha
#   export LANGFUSE_URL=http://localhost:3000
#   export OPENAI_API_KEY=sk-...
#   perl ex/langfuse.pl

use Langertha::Engine::OpenAI;

# Langfuse keys from env vars — auto-detected, no code changes needed!
#   LANGFUSE_PUBLIC_KEY=pk-lf-...
#   LANGFUSE_SECRET_KEY=sk-lf-...
#   LANGFUSE_URL=http://localhost:3000   (optional, defaults to cloud.langfuse.com)
#
# Or pass them explicitly:
#   Langertha::Engine::OpenAI->new(
#     langfuse_public_key => '...',
#     langfuse_secret_key => '...',
#     langfuse_url        => 'http://localhost:3000',
#   );

my $api_key = $ENV{OPENAI_API_KEY} || die "Set OPENAI_API_KEY\n";

die "Set LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY\n"
  unless $ENV{LANGFUSE_PUBLIC_KEY} && $ENV{LANGFUSE_SECRET_KEY};

# Keys are picked up from env vars automatically
my $engine = Langertha::Engine::OpenAI->new(
  api_key => $api_key,
  model   => 'gpt-4o-mini',
);

printf "Langfuse: %s (enabled: %s)\n", $engine->langfuse_url, $engine->langfuse_enabled ? 'yes' : 'no';
printf "Engine:   %s\n", $engine->chat_model;
printf "%s\n\n", "=" x 60;

# --- Call 1: Auto-instrumented simple_chat ---

printf "Call 1: simple_chat (auto-traced)\n";
my $r1 = $engine->simple_chat('Write a one-line joke about Perl.');
printf "  Response: %s\n", $r1;
printf "  Model: %s | Tokens: %s/%s/%s (prompt/completion/total)\n",
  $r1->model // '?',
  $r1->prompt_tokens // '?',
  $r1->completion_tokens // '?',
  $r1->total_tokens // '?';
printf "  Batch: %d events queued\n\n", scalar @{$engine->_langfuse_batch};

# --- Call 2: Another auto-traced call ---

printf "Call 2: simple_chat (auto-traced)\n";
my $r2 = $engine->simple_chat('Now write one about Python.');
printf "  Response: %s\n", $r2;
printf "  Batch: %d events queued\n\n", scalar @{$engine->_langfuse_batch};

# --- Call 3: Manual trace with custom metadata ---

printf "Call 3: Manual trace with custom metadata\n";
my $trace_id = $engine->langfuse_trace(
  name     => 'custom-workflow',
  metadata => { user_id => 'demo-user', session => 'example-run' },
);
printf "  Trace ID: %s\n", $trace_id;

my $r3 = $engine->simple_chat('What is the capital of Germany?');
$engine->langfuse_generation(
  trace_id => $trace_id,
  name     => 'geography-question',
  model    => $r3->model,
  input    => 'What is the capital of Germany?',
  output   => "$r3",
  usage    => {
    input  => $r3->prompt_tokens,
    output => $r3->completion_tokens,
    total  => $r3->total_tokens,
  },
);
printf "  Response: %s\n", $r3;
printf "  Batch: %d events queued\n\n", scalar @{$engine->_langfuse_batch};

# --- Flush all events to Langfuse ---

printf "%s\n", "-" x 60;
printf "Flushing %d events to Langfuse...\n", scalar @{$engine->_langfuse_batch};
my $flush_response = $engine->langfuse_flush;
printf "  HTTP %s\n", $flush_response->status_line;
printf "  Batch after flush: %d events\n\n", scalar @{$engine->_langfuse_batch};

printf "Done! Check your Langfuse dashboard at:\n";
printf "  %s\n\n", $engine->langfuse_url;
printf "You should see:\n";
printf "  - 3 auto-generated traces (from simple_chat calls 1, 2, 3)\n";
printf "  - 1 custom trace 'custom-workflow' with a 'geography-question' generation\n";
printf "  - Token usage, model info, and timing on each generation\n";
