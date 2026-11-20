# Raider — the autonomous agent (separate distribution langertha-raider)

Read this when running `Langertha::Raider`: multi-turn missions, questions back to the user,
history replay, metrics.

`cpanm Langertha::Raider`; then `use Langertha::Raider` (or `use Langertha qw( Raider )`).

```perl
my $raider = Langertha::Raider->new(
    engine         => $engine,           # with mcp_servers
    mission        => 'You are a code reviewer.',
    max_iterations => 10,
    # optional: max_context_tokens, context_compress_threshold, compression_engine,
    #           raider_mcp => 1 (self-tools: ask_user, pause, abort, ...), plugins => [...]
);
my $result = await $raider->raid_f('Review lib/App.pm');   # keeps history across raids
say $result;
if ($result->is_question) { $result = await $raider->respond_f('Yes, go ahead.') }
# also is_final / is_pause / is_abort; sync wrappers raid / respond
$raider->add_history(user => $text);   # replay persisted turns
$raider->clear_history;
my $m = $raider->metrics;              # { raids, iterations, tool_calls, time_ms }
```

The result class is `Langertha::Raider::Result`; core's `Langertha::Result` is only a stub.
Raider plugin hooks: `mcp-and-plugins.md`.
