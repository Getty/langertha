# ADR 0019 — Model-scoped capability corrections (amendment to ADR 0002)

- Status: accepted
- Date: 2026-09-10
- Tags: capabilities, tools, chat_f, roles, model-scoped

## Context

ADR 0002 built the capability picture in two layers: **layer 1** derives the flag set from the
composed role inventory (`%ROLE_TO_CAPS` in `Role::Capabilities`), and **layer 2** lets an
engine correct wire reality via `around engine_capabilities` — the one sanctioned escape hatch
for "the role inventory over-promises, the wire never accepts this field."

Both layers resolve **per engine**. That is the flaw on the tool / structured-output axis. A
red-team pass (karr k138) dumped `engine_capabilities` across the OpenAI-dialect fleet and found
literally one flag row — `tools_native tool_choice_auto tool_choice_any tool_choice_none
tool_choice_named response_format_json_object response_format_json_schema` — repeated across
~17 engines, ~11 of them wrong. The layer-2 escape hatch was in use only a handful of times and
none of those touched a tool-choice or structured-output flag, so the fleet advertised
capabilities it could not deliver.

That dishonesty is not cosmetic. `chat_f`'s auto-rewrite matrix (ADR 0005) decides whether to
forward a forced `tool_choice`, reroute it through `response_format`, or drop it — keyed on
`supports()`. When the flags are a constant, the decision is a constant: several engines
silently dropped a `tool_choice` the caller believed was forced, and the failure was a wrong
answer, not an error.

The deeper reason the flags were wrong is that **the tool / structured-output wire reality is
frequently per-model, not per-engine.** Within one endpoint, `kimi-k3` forbids a forced named
tool (its thinking mode disallows it) while its `kimi-k2.*` siblings accept one; a reasoning
model's clamps differ from its chat sibling on the same base URL. ADR 0002's engine-scoped
`around` cannot express "this field, but only for that model" without the engine hand-rolling a
`chat_model` branch inside its own `around` — which several engines had already begun to do
ad hoc (Gemini's `around` switches `thinking_budget` / `reasoning_effort` / `cached_content` on
a model regex).

## Decision

**Capability corrections resolve on two scopes, and the scope decides where the correction
lives.**

1. **Engine-wide reality → layer 2, `around engine_capabilities` (unchanged from ADR 0002).**
   When the endpoint never accepts a field regardless of model — MiniMax's `/v1` schema omits
   `tool_choice`/`response_format` entirely, OllamaOpenAI silently ignores `tool_choice` — the
   correction is model-independent and stays in the engine's `around`. This is the **outer
   endpoint gate.**

2. **Per-model reality → layer 3, a declarative `model_capability_corrections` table.** When the
   endpoint *carries* the field but a specific model or family rejects it, the engine declares
   an **ordered list of `( $matcher => \%overrides )` pairs** from `model_capability_corrections`.
   `Role::Capabilities::engine_capabilities` applies them, after layer 1, against the currently
   selected `chat_model`. The default returns an empty list, so engines that need no per-model
   refinement pay nothing.

3. **Layer 1 (role derivation, `%ROLE_TO_CAPS`) is untouched.** It remains the single source of
   the base flag set.

### Chosen form

- **Matcher** is either an exact model-id string (matched with `eq`) or a `qr//` regex (matched
  against `chat_model`). Model ids come in families (`gpt-5.6-*`, `kimi-k2.7-*`), so both a
  point match and a family match are first-class.
- **Overrides** is `{ $cap => 1 | 0 }` — `1` asserts a flag, `0` clears it.
- **Later matching entries win** on a shared flag (ordered list, last write wins).
- **Booleans only.** A pairwise / mutual-exclusion constraint between two capabilities (Cerebras
  and Groq reject `tools` + `response_format` in one body) is explicitly **not** expressible in
  this table — see *Future work* (karr k142).

The keystone user is `Engine::Moonshot`:

```perl
sub model_capability_corrections {
  return (
    'kimi-k3'       => { tool_choice_named => 0 },  # thinking forbids a forced tool
    qr/\Akimi-k2\./ => { tool_choice_any   => 0 },  # K2.x has no `required`
  );
}
```

`chat_model = 'kimi-k3'` loses `tool_choice_named`; a `kimi-k2.7-*` model loses `tool_choice_any`
instead; a future Moonshot model keeps the role-derived base until the table names it. This is
the **named form** of what Gemini's `around` already did ad hoc — the pattern is not new, it is
now a declared seam instead of an open-coded branch.

## Rationale

**Why a third layer rather than folding per-model logic into the existing `around`.** An engine
*could* read `chat_model` inside its `around` and branch — Gemini does. But that buries the
per-model matrix in imperative code, one engine at a time, invisible to any reader who greps for
the capability. A declarative, ordered table keyed on `chat_model` is greppable, testable
(k138's `t/78_model_scoped_capabilities.t` proves per-model *and* per-engine discrimination,
sabotage-verifiable), and gives the two distinct wire realities two distinct homes: "the
endpoint refuses this" vs "this model refuses this."

**Ordering semantics — recorded so nobody has to re-derive them.** The engine-wide `around`
*wraps* `engine_capabilities`, so it runs **outside** — and therefore **after** — the layer-3
table baked into the base method. The `around` is thus the last word over any per-model
correction. That is defensible on its own terms: **the endpoint gate is absolute** — if the wire
never accepts a field, no model can rescue it, so a layer-2 clear rightly overrides a layer-3
assert. In all current data the two layers touch **disjoint flags**, so the ordering is not
load-bearing today; the two in-flight consumers (k133 Anthropic fable/mythos, k140 OpenAI /
Gemini clamps) both use the dominant **clear-for-exceptions** shape (the base grants a flag,
a per-model entry clears it for the exceptional model), which is order-independent by
construction. The rule is written down here precisely because it is currently invisible.

**Precedent and related sites.** The mechanism names a pattern already present unnamed in
several places, none migrated in k138 (out of scope), all consolidation candidates:

- `Engine::Gemini`'s `around` — model regex → sets/clears `thinking_budget` / `reasoning_effort`
  / `cached_content`. The closest match to the new table; the strongest candidate to migrate.
- `Engine::OpenAI::_max_tokens_key`, `Reasoning::to_gemini_level`, `Reasoning::_is_fable_class`,
  `Engine::DeepSeek::reasoning_kwargs_for` — other per-model gating, on the reasoning/request-side
  axis rather than the capability flags.

## Consequences

- **The mechanism is ready** for the two waiting tickets: k133 (Anthropic native structured
  output — `fable`/`mythos` reject the ADR 0005 synthetic-tool rewrite) and k140 (OpenAI /
  Gemini reasoning and structured-output clamps). Both are per-model, both fit the table.
- **Only `Engine::Moonshot` uses layer 3** so far. The rest of the k138 pass is a broad
  **layer-2** honesty sweep informed by the same wire-reality matrix: MiniMax, OllamaOpenAI,
  LlamaCpp, SGLang, Hetzner, DeepSeek, and Scaleway each clear engine-wide flags their endpoint
  never delivers. The two mechanisms are complementary, not competing: pick the scope that
  matches the reality.
- **The flag contract is unchanged:** a capability flag still means *the wire accepts the
  field*, not that a model will honor it — now resolved for the selected `chat_model` rather than
  once per engine. `supports()` and the `chat_f` matrix are downstream and need no change.
- **The correction matrix is verified-but-not-infallible — cross-check the canonical→wire
  serialization before trusting a "wrong flag" reading.** Building k138 surfaced one such error
  in the advisor matrix (House Rule 5 — surface the conflict, don't average it): **Scaleway
  `tool_choice_any` is NOT wrong.** The matrix flagged it by reading OpenAI's literal `"any"`,
  but Langertha's canonical `any` serializes to the wire token `tool_choice: "required"`
  (`Langertha::ToolChoice::to_openai`), and Scaleway's enum is exactly `none | auto | required` —
  so `any` is accepted. Only `parallel_tool_use` (inert on Scaleway) and the deprecated
  `response_format_json_object` were cleared there. The lesson is load-bearing for every future
  correction: a capability flag names a *canonical* capability, and whether the wire accepts it
  is decided by what the value object *emits*, not by matching the flag's spelling against the
  provider's enum.

## Future work

- **karr k142** — pairwise / mutual-exclusion capability constraints. Cerebras and Groq reject
  `tools` + `response_format` in one request; the boolean table (even model-scoped) cannot
  express "these two capabilities are mutually exclusive per call." This also dents the ADR 0005
  premise that structured output and forced tools are freely interchangeable. Out of scope here;
  do not stretch the boolean table to fake it. **Update (2026-09-14):** the interim guard shipped
  as **ADR 0021** — a per-engine `_check_capability_exclusions` croak at the `chat_f`/streaming
  layer, above this table, that turns the known provider 400 into a clear local error. The
  model-scoped generalization this bullet describes (a new per-model seam beside the boolean
  table) remains parked for the maintainer; karr k142 stays open for it.
- **Gemini consolidation** — migrate `Engine::Gemini`'s ad-hoc model-regex `around` into
  `model_capability_corrections`. It is the pattern this ADR names; folding it in would remove
  the last open-coded per-model capability branch. Deliberately not done in k138 (Gemini is not
  on the OpenAI-dialect axis the ticket scoped). Not yet ticketed — a consolidation candidate,
  not a defect.

`CONTEXT.md` carries the vocabulary (`capability axis`, `model_capability_corrections`). See
ADR 0002 (the base decision this amends), ADR 0005 (the auto-rewrite matrix `supports()` feeds),
and ADR 0015 (per-family `around` corrections, the layer-2 sibling of this per-model table).
