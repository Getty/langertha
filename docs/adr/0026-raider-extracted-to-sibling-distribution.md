# ADR 0026 — Raider/Raid extracted to the sibling distribution langertha-raider; renamed core-namespace packages kept as reserved stubs

- Status: accepted
- Date: 2026-09-20
- Tags: distribution, raider, raid, mcp, cpan, dependencies, public-api

## Context

The autonomous agent (`Langertha::Raider`, ~2200 lines) and the `Raid` orchestration layer
(`Langertha::Raid`, `Raid::Loop/Parallel/Sequential`, `Langertha::RunContext`,
`Langertha::Role::Runnable`) shipped inside the core `Langertha` distribution, but core never
hard-depended on them: the only couplings were a lazy `use_module('Langertha::Raider')` sugar
path in `Langertha.pm` (`use Langertha qw( Raider )`) and a runtime `->isa('Langertha::Raider')`
string check in `Plugin.pm` — everything else was POD cross-references. The standalone `raider`
app (`App::Raider`, its own repo) already `requires 'Langertha'` and imported `Langertha::Raider`
directly.

That is the exact shape of a sibling distribution: the agent depends on the framework, never the
reverse — the same relationship `langertha-knarr` and `langertha-skeid` already have to core. The
agent framework and the `App::Raider` CLI are being merged into one new distribution,
`langertha-raider`, which will carry the `raider` binary and own the `Langertha::Raider::*`
namespace. This ADR records the **core-side** decision (what leaves, what stays, and why); the
new distribution's own assembly is out of scope here.

## Decision

Extract the agent/orchestration layer from core into the `langertha-raider` sibling distribution,
partitioning every affected package by one rule:

- **Migrates 1:1 (same name in the sibling) → removed from core.** `Langertha::Raider`,
  `Langertha::Raider::Result`, `Langertha::Raid`, `Raid::Loop/Parallel/Sequential`,
  `Langertha::RunContext` and `Langertha::Role::Runnable` keep their names in `langertha-raider`,
  so the name lives on there and core simply drops them.
- **Renamed on the way over → a reserved-namespace stub stays in core under the old name.**
  `Langertha::MCP::Client` becomes `Langertha::Raider::MCP` (a self-contained `Net::Async::MCP`
  subclass); `Langertha::Result` is folded into a now self-contained `Langertha::Raider::Result`.
  Because the sibling does **not** ship those old core-namespace names, core keeps a minimal
  `package …; 1;` stub for each (`lib/Langertha/Result.pm`, `lib/Langertha/MCP/Client.pm`) whose
  only job is to keep the name indexed to the `Langertha` distribution on PAUSE.

Core deliberately **keeps** the seams the agent was built on, because they are used without it
(plain `Langertha::Chat` tool calling, the plugin system): `Langertha::Role::Tools` /
`chat_with_tools_f`, `Langertha::Role::PluginHost`, `Langertha::Plugin`, `Langertha::Result` (as a
stub). `mcp_servers` is retyped in POD as a duck-typed `ArrayRef` of any `Net::Async::MCP`-compatible
client (the attribute was always `isa => 'ArrayRef'`, never pinned to `Langertha::MCP::Client`), so
core tool calling needs no MCP client class of its own — its tests drive the loop through an
in-tree `t/lib/Test/MockMCP.pm`. The lazy `use Langertha qw( Raider )` sugar and the
`->isa('Langertha::Raider')` guard stay verbatim; both are no-ops until `langertha-raider` is
installed, at which point the sugar's `use_module` resolves.

Dependencies follow the code: `Net::Async::MCP` is dropped from core, and `IO::Async` +
`Net::Async::HTTP` are added as explicit `requires`. Both were used directly by core's async `_f`
path (`Role::Chat` `_build__async_loop` / `_build__async_http`, `Role::Runtime::MetricsPoll`,
`Role::Tools`) but were never declared — they reached the dependency closure only transitively via
`Net::Async::MCP`, so removing it without declaring them would break core async on a clean install.
`Math::Vector::Similarity` and `MooseX::NonMoose` stay (non-Raider core consumers).

## Rationale

The stub-vs-remove split keeps the CPAN namespace tidy in both directions: `Langertha::*`
core-namespace names remain indexed to the `Langertha` distribution rather than being served by a
sibling dist, while `langertha-raider` publishes only `Langertha::Raider::*`. A 1:1-migrated name
needs no stub — it is still published, just from the sibling. A renamed name would otherwise vanish
from the index entirely, so the stub preserves continuity for anyone who had it and reserves the
namespace for future core use.

## Consequences

- **Breaking for the core distribution** (`feat!:`). Installing `Langertha` alone no longer gives
  you `Langertha::Raider` et al.; install `langertha-raider`. `Langertha::Result` and
  `Langertha::MCP::Client` still load but are empty — code that called their methods must move to
  `Langertha::Raider::Result` / `Langertha::Raider::MCP`.
- Core's async and tool-calling features are unchanged and still first-class; the extraction does
  not touch core's hard dependency graph beyond the declared-dependency correction above.
- ADR 0007 (Raider session archive) and ADR 0008 (Raider self-tools) describe decisions whose code
  now lives in `langertha-raider`; they stay here as historical record of how Raider reached this
  shape. This ADR does not supersede them.
- The reserved-stub pattern is reusable: any future `Langertha::*` package that is renamed as it
  moves to a sibling should leave a stub behind; one that keeps its name should not.

## Future work

- `langertha-raider` assembly (rename, `dist.ini`/`cpanfile`, `App::Raider` merge, tests) is
  tracked on that repo's board — not core work.
- karr #172 (Raider session-history embeddings) targets code that now lives in `langertha-raider`
  and should move to that board.
