# ADR 0031 — `Usage.input_tokens` keeps the wire's meaning; `input_includes_cache` records it, and `Pricing` prices each token once

- Status: accepted
- Date: 2026-09-25
- Tags: usage, pricing, cost, prompt-cache, value-objects
- Cross-links: ADR 0018, ADR 0028
- karr: k263 (for skeid k28)

## Context

`Langertha::Pricing->cost_for` priced `Usage.input_tokens` at the rule's input rate and
nothing else. Pricing prompt-cache reads and writes at their own rates needs to know whether
`cached_tokens` / `cache_write_tokens` are already part of `input_tokens`, and the wires
disagree:

| Wire | cache counts | part of the input count? | evidence |
|---|---|---|---|
| OpenAI Chat (and compatibles) | `prompt_tokens_details.{cached,cache_write}_tokens` | yes | `akiopenai_chat_response`: 65 prompt, 64 cached |
| Open-Responses (OpenAI, Perplexity) | `input_tokens_details.*` | yes | `responses_web_search`: 8542 in, 4394 written; `perplexity_agent_search`: 4071 in, 4068 written |
| Gemini | `cachedContentTokenCount` | yes | Gemini docs |
| AKI native | `num_cached_tokens` | yes | subset of `prompt_length` (Engine::AKI) |
| Anthropic | flat `cache_read_input_tokens` / `cache_creation_input_tokens` | no | Anthropic docs |

`Usage` did not record which case it had, so a pricer could not avoid either billing a cached
token twice (Anthropic-style addition on an OpenAI usage) or not at all.

Sibling distributions (skeid, knarr, raider) record and bill on `input_tokens` today, so
redefining it as "always the whole prompt" or "always the uncached part" would silently change
their numbers.

## Decision

1. `input_tokens` keeps the meaning the wire gives it.
2. `Usage` gains `input_includes_cache` (`Maybe[Bool]`), set by `from_hash` / `from_raw` from
   where the cache counts were found: nested `*_details`, Gemini and the flat `cached_tokens`
   → true; Anthropic's flat keys → false; no cache count → `undef`. One flag covers reads and
   writes because every known wire reports both the same way; a mixed hash is marked false.
3. `Usage->uncached_input_tokens` is `input_tokens` when the flag is false, else
   `input_tokens - cached - write` clamped at zero. `undef` counts as included, which is what
   `total_tokens = input + output` already assumes.
4. `Pricing` rules take optional `cached_input_per_million` and `cache_write_per_million`.
   A rule with neither is priced exactly as before. A rule with either one prices
   `uncached_input_tokens` at the input rate plus reads and writes at their rates, a missing
   one falling back to the input rate — Langertha never assumes a discount the rule did not
   state.
5. `Cost` gains `cache_read_usd` / `cache_write_usd` (default 0), summed into `total_usd` and
   emitted by `to_hash` as `cache_read_cost_usd` / `cache_write_cost_usd`.

## Consequences

- Cache pricing is opt-in per rule, so no existing rule changes its result. A rule without
  cache keys keeps under-billing Anthropic cache traffic (those tokens are not in
  `input_tokens`); adding a cache key is the fix.
- Built with `new` and no flag, a Usage is read as "included"; callers building one from an
  Anthropic-shaped count pass `input_includes_cache => 0`.
- The flag describes the spelling, not the provider. AKI.IO's `/anthropic` shim reports
  `input_tokens` 65 with `cache_read_input_tokens` 64 for the same request its OpenAI face
  reports as 65 / 64 — its count includes the reads — but it is marked false. An engine-scoped
  correction (ADR 0018 layer 3) is follow-up work; the other `/anthropic` shims are unverified.
- `Usage->merge` still sums only input and output; it drops the cache counts and the flag.
