# ADR 0027 — Synchronous LWP fallback for the async `_f` transport; IO::Async + Net::Async::HTTP become recommends

- Status: accepted
- Date: 2026-09-21
- Tags: transport, async, dependencies, cpan, roles, http
- karr: #188

## Context

ADR 0026 declared `IO::Async` and `Net::Async::HTTP` as explicit `requires` of core: they had
always been used directly by the async `_f` path but reached the dependency closure only
transitively via `Net::Async::MCP`, which the Raider extraction dropped. Declaring them was the
correct fix at that moment — but it also froze a heavy async stack into every install, including
installs that never call a `_f` method.

Only the async path needs them. The **synchronous** path (`simple_chat`, `chat`,
`execute_streaming_request`) already runs over `LWP::UserAgent` via `Langertha::Role::HTTP` and
touches neither module. The async seam itself was already thin and duck-typed on one contract —
`_async_http->do_request( request => $req [, on_header => sub {...}] ) → Future<HTTP::Response>`,
where 4xx/5xx **resolve** the future (the caller checks `is_success`), consumed non-streaming at
`Role::Chat` and streaming via the `on_header`→chunk-sub form. Both `Role::Chat` and
`Role::Runtime::MetricsPoll` carried a private, undocumented copy of the same
`_async_loop`/`_async_http` lazy builders (`Net::Async::HTTP->new`, `$loop->add($http)`), and
because those were plain Moose attributes with open `init_arg`, a client was already injectable —
only the default builder was hardcoded to the async stack.

## Decision

Give the `_f` path a synchronous fallback so `IO::Async` and `Net::Async::HTTP` can move from
`requires` to `recommends`, without changing the `_f` API.

1. **A synchronous HTTP backend** — `Langertha::Request::SyncHTTP` — satisfies the exact
   `do_request` contract over an injected `user_agent` (an `LWP::UserAgent`) and returns
   `Future->done($response)`. No event loop: an already-complete `await` resolves synchronously,
   so the whole `_f` chain runs sync and the caller's `->get` returns immediately. Its streaming
   branch bridges LWP's per-chunk content callback (`($data, $response, $protocol)`, live-verified
   against LWP::UserAgent 6.83) to the `on_header`→chunk-sub contract, ending with the `undef`
   end-of-body signal — so `_process_stream_buffer` and the chunk callbacks fire exactly as on the
   async path (blocking, not truly incremental). Error parity is automatic: LWP accumulates error
   bodies on the response and the future resolves with it, matching `Net::Async::HTTP`
   (`fail_on_error` defaults false — also live-verified, at 0.50) and the existing
   `Role::HTTP` error-body handling.

2. **One shared selection seam** — `Langertha::Role::AsyncHTTP` — owns the `_async_http` /
   `_async_loop` attributes and the backend choice, ending the duplication: an injected
   `_async_http` wins verbatim (bring-your-own-client is now a supported feature, not an accident of
   private attributes); else `Net::Async::HTTP` if `eval { require }` succeeds (build `_async_loop`,
   add the client — today's behaviour); else the `SyncHTTP` shim plus one `carp` per process.
   `_async_loop` is built **only** on the `Net::Async::HTTP` path; the sync path never creates an
   event loop.

3. **Both consumers compose the role.** `Role::Chat` and `Role::Runtime::MetricsPoll` drop their
   local builders and `with 'Langertha::Role::AsyncHTTP'`. MetricsPoll's synchronous wrappers
   (`poll_metrics`, `export_otlp`) now drive `_async_loop->await` **only when the future is
   pending**; on the sync fallback the future is already ready, so they return its result without
   touching `_async_loop` — keeping IO::Async out of the sync path there too.

4. **Dependencies.** `IO::Async` and `Net::Async::HTTP` (and `IO::Async::SSL`) become
   `recommends`; `LWP::UserAgent` and `LWP::Protocol::https` are explicit `requires` (the sync
   transport and the fallback both need them). A clean `cpanm Langertha` installs a working,
   sync-capable core; async users add the recommends (or `cpanm --with-recommends`).

## Rationale

The value object + shared role is the same seam-consolidation pattern the codebase already uses for
wire translation (ADR 0001) and observability (ADR 0014): a duck-typed contract that had two
hardcoded copies becomes one injectable, documented backend selector with a value-object client
behind it. Because every `await` on an already-complete future resolves without a loop, the sync
shim needs no reactor and no threads — the degradation is purely sequential/blocking, and nothing
downstream (`Response`, `tool_calls`, streaming chunks, timing) can tell the difference. Making the
two async modules `recommends` reverses ADR 0026's dependency line deliberately, now that the code
no longer forces them: the honest declaration is "core is sync-capable; async is optional".

Full loop-agnosticism (AnyEvent/Mojo as the *loop*, real concurrency on a non-IO::Async reactor) is
out of scope; the inject-your-own-`_async_http` seam this ADR formalizes is the hook a future
loop-adapter layer would build on.

## Consequences

- A clean install with neither async module works: `_f` methods run synchronously (sequential,
  blocking) and warn once per process. Real concurrency requires the recommends or an injected
  client. This degradation is documented in the `_f` POD, the `_async_http` attribute POD, and the
  `SyncHTTP` POD.
- The private `_async_http` / `_async_loop` attributes are now a documented, supported injection
  point (their names are unchanged — surgical, no rename, no public alias).
- `Role::Runtime::MetricsPoll`'s sync wrappers no longer unconditionally spin an IO::Async loop;
  on the async backend behaviour is unchanged, on the sync backend they create no loop.
- Reverses ADR 0026's `requires` on `IO::Async` + `Net::Async::HTTP` (relates to 0026); the
  `do_request` resolve-on-error contract is unchanged and now honoured by two backends.

## Future work

- A pluggable event-loop adapter layer (AnyEvent/Mojo) that gives real concurrency on a non-
  IO::Async reactor — deferred; it would consume the `_async_http` injection seam formalized here.
