# ADR 0009 — Request-side control params are modeled as a per-concern wire-format quartet

- Status: accepted
- Date: 2026-06-26
- Tags: engines, roles, value-objects, wire-format, reasoning, prompt-cache, capabilities

## Context

Some request-side control knobs vary by provider on *both* axes ADR 0001 already
fights on the tools side: the accepted **vocabulary** differs, and the **placement** of
the field in the request body differs. Reasoning effort is the worst case — the same
normalized intent ("think harder") is a flat `reasoning_effort` string on OpenAI
`/chat/completions`, a nested `reasoning:{effort}` on the Responses API,
`output_config.effort` plus `thinking:{type:adaptive}` on Anthropic Messages, and a
collapsed binary `generationConfig.thinkingConfig.thinkingLevel` (`low`/`high`) on
Gemini — and each wire accepts only a subset of the normalized value set. Prompt caching
is similarly split: Anthropic exposes an explicit `cache_control` enable breakpoint with a
TTL, while OpenAI caches automatically and the only request-side lever is the
`prompt_cache_key` routing hint.

The pull to model each of these ad-hoc, per engine, is strong — and the codebase already
had one such ad-hoc knob that proves the cost: `AnthropicBase` carried an `effort`
attribute that emitted a **top-level `effort` key**, which the Messages API silently
ignores (a dead request field, exactly the class of bug ADR 0004 names). The placement was
wrong, not the idea.

The deeper structural question this decision answers: ADR 0001 routes the tools seam
through value objects keyed by a single `tool_wire_format` tag — can a control knob just
reuse that tag? No. Engines that agree on `tool_wire_format=openai` (DeepSeek, MiniMax,
Groq) **disagree** on the reasoning field: MiniMax's OpenAI endpoint rejects it entirely,
DeepSeek's V4 line takes a flat `reasoning_effort` while its legacy V3.2 line took a
`thinking:{type:enabled}` toggle, and Groq accepts the flat form. One global wire format
cannot express that. Wire dialect is **per concern**.

## Decision

Each request-side control param that varies by provider is modeled as a consistent
**quartet**, not as ad-hoc per-engine code. The two knobs that landed together —
`Langertha::Role::ReasoningEffort` / `Langertha::Reasoning` and
`Langertha::Role::PromptCache` / `Langertha::PromptCache` — are the same shape and are
recorded as one decision.

1. **A predicate-gated role holds the normalized attribute(s).** `Role::ReasoningEffort`
   carries `reasoning_effort` (normalized vocabulary: the OpenAI superset
   `none|minimal|low|medium|high|xhigh|max`); `Role::PromptCache` carries `prompt_cache`
   / `prompt_cache_ttl` / `prompt_cache_key`. The field is emitted only when set — the
   same "only when present" discipline as `Role::Temperature`, so an unset knob means the
   model's own default applies and no field reaches the wire.

2. **A per-format value object owns the wire shape.** `Langertha::Reasoning` and
   `Langertha::PromptCache` each carry `to_<fmt>` serializers plus a `to($fmt)` dispatch
   (`croak` on an unknown tag). Each serializer does two jobs: it **clamps** the
   normalized vocabulary to what that wire accepts (returning an empty list when the value
   has no equivalent — e.g. Anthropic drops `none`/`minimal`, OpenAI drops `max`, Gemini
   collapses to `low`/`high` split at `high`), and it **places** the field correctly
   (Anthropic `output_config.effort` + `thinking:{type:adaptive}`; OpenAI flat
   `reasoning_effort`; Responses nested `reasoning:{effort}`; Gemini
   `generationConfig.thinkingConfig.thinkingLevel`; Anthropic `cache_control`; OpenAI
   `prompt_cache_key`). This is exactly the instinct of ADR 0001 — the
   Tool/ToolCall/ToolResult/ToolChoice value objects own tool wire translation so engines
   stay thin — applied to a new family of value objects.

3. **A dedicated `*_wire_format` tag per concern, deliberately separate from
   `tool_wire_format`.** `reasoning_wire_format` and `cache_wire_format` each default off
   the engine base-class hierarchy (`_build_*` returns `openai`; `AnthropicBase` overrides
   both to `anthropic`; `Gemini` sets `reasoning_wire_format` to `gemini`;
   `OpenAIResponses` to `responses`) — the same base-encodes-the-dialect arrangement as
   ADR 0006, but **one tag per concern**. This is the load-bearing new point: a single
   global wire format is insufficient because engines sharing one dialect for one concern
   diverge on another. Wire dialect is per concern, so the tag is per concern.

4. **Capability flags ride the existing registry (ADR 0002).** `%ROLE_TO_CAPS` registers
   `Role::ReasoningEffort → reasoning_effort` and `Role::PromptCache → prompt_cache
   prompt_cache_key`, and base classes / engines clear flags the wire cannot honor via
   `around engine_capabilities`: `OpenAIBase` clears `prompt_cache` (OpenAI caches
   automatically — only the routing key applies), `AnthropicBase` clears
   `prompt_cache_key` (it has the enable breakpoint but no routing key),
   `MiniMax`/`Perplexity` clear `reasoning_effort`, `Perplexity` also clears
   `prompt_cache_key`. As ADR 0002 establishes, the flag means **the wire accepts the
   field**, not that any given model will honor it (every reasoning field 400s on a
   non-reasoning model). Prompt caching is request-side-asymmetric, which is *why* it gets
   two flags from one role rather than one.

5. **Engines override the kwargs dispatch for model-gated divergence below the tag's
   resolution.** The role's `reasoning_kwargs` / `prompt_cache_kwargs` is the seam the
   request builder calls (`Role::OpenAICompatible` emits both, `can`-guarded, in its chat
   and stream requests; `AnthropicBase` and `Gemini` call them in their own builders).
   When divergence lives *within* a shared wire format — below the format tag's resolution
   — the engine overrides the method: `DeepSeek::reasoning_kwargs` sniffs the model (V4
   flat `reasoning_effort` vs legacy V3.2 `thinking:{type:enabled}`), and
   `MiniMax`/`Perplexity` stub it to an empty list.

As part of this, the dead-key bug is fixed: `AnthropicBase`'s top-level `effort` becomes
`output_config.effort` + `thinking:{type:adaptive}` via `Langertha::Reasoning`, with
`effort` kept as a back-compat alias of `reasoning_effort` (seeded in `BUILDARGS`).
Live-verified HTTP 200 on `claude-opus-4-8`. ADR 0004's "extras extend the body" was the
right mechanism; only the *placement* was wrong, and the value object is now where
placement is decided once.

## Rationale

The tools seam (ADR 0001) proved that wire reality belongs in canonical value objects
dispatched by a per-engine tag, leaving engines as configuration. Request-side control
knobs are the same kind of problem — normalized intent in, provider-shaped field out — so
they get the same shape rather than a second, ad-hoc style. The one genuinely new insight
is that the tag must be **per concern**: `tool_wire_format` cannot be reused because the
agreement it encodes (which tool dialect) does not imply agreement on reasoning or
caching. Splitting the tag per concern is what keeps DeepSeek, MiniMax, and Groq — three
`tool_wire_format=openai` engines — able to disagree about reasoning while still sharing
everything else.

Keeping the value object responsible for both clamping and placement means a wire-shape
fix happens once and every engine of that format inherits it — and it makes the dead-key
class of bug structurally hard to reintroduce, because no engine writes the field
position by hand anymore.

## Consequences

- **A new request-side control concern** = a new quartet: a predicate-gated role, a value
  object with `to_<fmt>` + `to()`, a `*_wire_format` tag defaulting off the base
  hierarchy, a `%ROLE_TO_CAPS` entry (plus `around` corrections where the wire
  disagrees), and a `can`-guarded emission in the request builders.
- **A provider variation within an existing concern** = either a new tag value with a new
  `to_<fmt>` branch (a whole new dialect) or, when the split is below the tag — e.g.
  model-gated — an engine-level override of the `*_kwargs` method. Pick by where the
  divergence actually lives.
- **A capability flag means the wire accepts the field, not that the model honors it.**
  Prompt caching therefore carries two flags (`prompt_cache` enable breakpoint vs
  `prompt_cache_key` routing hint), each cleared on the family whose wire lacks it.
- The normalized vocabularies (`reasoning_effort`'s seven values, the cache TTL windows)
  are the stable public contract; what each wire accepts is the value object's private
  knowledge, expressed as clamping.

## Future work

- **`CONTEXT.md` covers only the tool wire-translation vocabulary.** It does not yet name
  `reasoning_wire_format` / `cache_wire_format`, `Langertha::Reasoning` /
  `Langertha::PromptCache`, or the "per-concern wire format" relationship. Extending the
  domain language so these sibling seams are first-class terms (not just analogues of the
  tools seam) would keep the vocabulary truthful. Candidate karr follow-up.
- **DeepSeek's V3.2 `thinking:{type:enabled}` mapping is flagged for live re-verify** in
  the code comment — the V4 path is live-verified, the legacy toggle is not.

## Cross-links

- ADR 0001 — tool wire-translation via value objects keyed by `tool_wire_format`; this
  ADR applies the same value-object-owns-the-wire pattern to control params and explains
  why the *tag* must be per concern rather than shared.
- ADR 0002 — capabilities derive from the composed role inventory; the new flags are
  registered in `%ROLE_TO_CAPS` and corrected via `around engine_capabilities`.
- ADR 0004 — provider wire extras extend the request body; this ADR fixes the Anthropic
  `effort` *placement* (dead top-level key → `output_config.effort` +
  `thinking:{type:adaptive}`) by moving placement into the value object.
- ADR 0006 — engine inheritance encodes the wire dialect; this ADR extends that from one
  dialect tag to one tag *per concern*.
