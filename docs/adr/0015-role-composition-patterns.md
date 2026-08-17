# ADR 0015 — `-excludes` and per-family `engine_capabilities` correction are canonical patterns

- Status: accepted
- Date: 2026-08-15
- Tags: roles, capabilities, composition, wire-format, anthropic, openai, generation-parameters

## Context

The doku audit on 2026-08-14 surfaced two complementary drifts in the engine /
role composition lane. They are independent observations, but both live in the
same seam (Perl role composition + how dialect bases override collision-prone
defaults), and they share the same fix: capture each pattern as the canonical
shape, written down once, so the next reader doesn't have to rediscover it from
scattered code comments.

### Finding 1 — `-excludes` is a non-obvious role-composition workaround

When `Langertha::Engine::AnthropicBase` composes its roles, it uses the
`with map { 'Langertha::Role::'.$_ } qw(...)` pattern (AnthropicBase.pm:14-25),
not the simpler `with 'Langertha::Role::X'`. The reason isn't taste — it's
**collision resolution**. Several `_build_*_wire_format` and `content_format`
methods live on more than one role, and an unqualified `with` would either
fail at class-load time or pick arbitrarily. The base compiles the role list
explicitly via a `map` and then subtracts the conflicting roles to keep the
wiring unambiguous.

Only two lines in the codebase document why (`AnthropicBase.pm:14-25`), and the
pattern recurs in `Engine::OpenAIBase` (which uses the same `map` shape for
the same reason — `OpenAICompatible`, `OpenAPI`, `Models`, etc. all want to
override `_build_*_wire_format`, and the explicit list sets the order). A new
reviewer reading the bare `with map { ... } qw(...)` sees an unusual idiom and
has no quick pointer to "this is how we resolve dialect-base composition
collisions".

### Finding 2 — Per-family `engine_capabilities` correction is symmetric but undocumented side-by-side

Both dialect bases correct the wire reality in an `around engine_capabilities`
clause, but they correct *different* flags, for *opposite* reasons:

- `Langertha::Engine::OpenAIBase.pm:31-36` — the OpenAI family caches
  automatically (there is no request-side breakpoint), so it deletes
  `prompt_cache_key` and keeps only the `prompt_cache` enable flag. Comment:
  *"Clear the Anthropic-style enable flag here so the whole family advertises
  only the key (ADR 0002)."*
- `Langertha::Engine::AnthropicBase.pm:32-37` — the Anthropic family has the
  `cache_control` enable breakpoint but no OpenAI-style routing key, so it
  deletes `prompt_cache_key` and keeps only the `prompt_cache` flag. Comment:
  *"Clear the key flag so only the enable flag is advertised (ADR 0002)."*

The two comments read as if one is the inverse of the other, but each is
written in isolation. A reader has to flip between the two files to see the
symmetry. The narrower claim in the comments ("the inapplicable flag for this
family") only makes sense once you have both directions in front of you.

### Finding 3 — the generation-parameter block: `Role::OpenAICompatible` is also the asymmetrizer

The doku audit also flagged that `Role::OpenAICompatible::chat_request` /
`chat_stream_request` assemble the generation parameters (temperature,
response_format, response_size, reasoning / cache kwargs) through a small
boilerplate pattern (`$self->has_temperature ? ( temperature => ... ) : ()`,
`$self->reasoning_kwargs_for`, `$self->prompt_cache_kwargs_for`, ...). The
Anthropic dialect role `Role::AnthropicCompatible` duplicates this exact pattern
inline in `chat_request` / `chat_stream_request` because no shared
generation-parameter helper exists yet.

This is not a bug — it's a deliberate split between *wire-aware* assembly
(Anthropic folds `parallel_tool_use` into `tool_choice`, translates
`response_format` to a synthetic tool, threads `inference_geo`, etc. — all
dialect-specific) and *wire-agnostic* emission (OpenAI's generic block). The
asymmetry is real but invisible — there's no documented decision to point to.
The langertha-rules audit text mistakenly references "579d0c8 / ADR 0013" for
this; in fact those tickets concern *envelope* extraction (separate work), not
the generation-parameter block.

## Decision

### 1. The `-excludes` pattern is the canonical way to resolve dialect-base role composition

Concretely: when a dialect base class needs to compose a *role-inventory-style*
set of roles (the always-on family — models/chat/streaming/etc.) and *some of
those roles collide* on method names (`_build_tool_wire_format`,
`_build_cache_wire_format`, `content_format`, `stream_format`, …), the
canonical shape is:

```perl
extends 'Langertha::Engine::Remote';

with map { 'Langertha::Role::'.$_ } qw(
  Models Chat Temperature ReasoningEffort PromptCache ResponseSize
  SystemPrompt ResponseFormat Streaming Tools
);
```

and on dialect-specific subclasses that override the conflicting defaults, an
explicit `-` exclusion in the role list (e.g. `-Capabilities` if `Capabilities`
conflicts with a dialect override). The `map` form is canonical B<not> because
it's terse but because it makes the *intentional* list visible — every role
listed is one the dialect base keeps, and anything not listed (because the
subclass takes over) is deliberately absent. The pattern is the explicit
answer to "why doesn't `AnthropicBase` just `with 'Role::Tools'`?" — it does,
because Tools doesn't collide, but the `_build_*_wire_format` defaults come
from the class (`AnthropicBase.pm:460`) so the list stays compact.

This is **not** a new decision — it's the pattern in
`OpenAIBase.pm:10-22` and `AnthropicBase.pm:14-25` already. The ADR captures
the pattern so the next contributor doesn't re-derive it.

### 2. Per-family `engine_capabilities` correction is a documented direction-pair

`ADR 0002` established that the engine's `around engine_capabilities` is the
sanctioned escape hatch when the wire reality disagrees with the role
inventory. The cache-control flag is the clearest example of *opposite
correction directions per family*, and that symmetry gets canonical text:

| Family | Cache flag kept | Cache flag deleted | Rationale |
|---|---|---|---|
| OpenAI (and all subclasses of `OpenAIBase`) | `prompt_cache_key` | `prompt_cache` | OpenAI caches automatically; there is no request-side enable breakpoint. The `prompt_cache_key` is the only knob the wire exposes. |
| Anthropic (and all subclasses of `AnthropicBase`) | `prompt_cache` | `prompt_cache_key` | Anthropic's `cache_control` block is an *enable breakpoint* per content block. There is no equivalent routing-key field. |

The direction-pair table is the canonical reference; future per-family
corrections (e.g. when a new dialect base is added) follow the same rule —
**delete the inapplicable flag, keep the applicable one, with a comment
naming which flag the wire doesn't speak**. Both directions live in
`ADR 0002`'s escape-hatch paragraph; this ADR adds the explicitly paired
form so the symmetry is discoverable from one place.

### 3. The generation-parameter block asymmetry is a deliberate dialect split (and a future refactor target)

The boilerplate generation-parameter emission in `Role::OpenAICompatible` (`has_temperature`,
`reasoning_kwargs_for`, `prompt_cache_kwargs_for`, `stream`, …) is *duplicated* into
`Role::AnthropicCompatible` rather than shared through a common helper,
because **the dialect-aware fields (`response_format` translation to a synthetic
tool, `tool_choice` ↔ `parallel_tool_use` folding, `inference_geo`,
`anthropic-version`) all require the wire envelope in scope**. Extracting
the wire-agnostic subset (e.g. `temperature`, `reasoning_kwargs_for`,
`prompt_cache_kwargs_for`) into a shared helper is a worthwhile follow-up
(working name `Langertha::Role::GenerationParams`, or a
`generation_kwargs_for` method on each base — *not* `knobs_kwargs_for`, which
`Langertha::Role::RuntimeKnobs` already owns for the self-hosted prefix-cache
knobs), but it cannot happen until each side's dialect-aware logic is named as
"dialect" not "parameter". Recording this as a *deliberate asymmetry, not
oversight* prevents a future reviewer from misreading the duplicated
boilerplate as drift.

Concretely:

- **Status quo** — `Role::AnthropicCompatible::chat_request:180-187` /
  `chat_stream_request:406-413` emit the generation parameters inline because
  they share scope with the wire-aware blocks. Until the wire-envelope
  extraction (579d0c8, ADR 0013) this block sat in `Engine::AnthropicBase`; the
  move changed its address, not its shape.
  `Role::OpenAICompatible::chat_request:323-335` / `chat_stream_request:448-460`
  emit a similar set in the same shape, also inline, also dialect-agnostic at
  the emission level but also dialect-aware (the `stream => JSON->true/false`
  placement, the `parallel_tool_calls` placement differ).
- **Future refactor** — extract the wire-agnostic subset
  (`temperature`, `reasoning_kwargs_for`, `prompt_cache_kwargs_for`,
  `has_response_format`) into a `Langertha::Role::GenerationParams` helper or a
  `generation_kwargs_for` method on each base. The first precondition is
  **met**: #64 landed (579d0c8, ADR 0013) and `Role::AnthropicCompatible` is
  that stable home, so both dialect sides are roles composed into thin bases.
  What remains is the second precondition — `Role::OpenAICompatible`
  reformulating its own generation-parameter block as a call to the helper —
  plus tests proving the request bodies are identical before and after. The
  extraction is therefore concretely actionable follow-up work, not blocked
  work.

## Rationale

ADR 0002 already authorized the `around engine_capabilities` escape hatch.
ADR 0006 split inheritance (wire dialect) from composition (capabilities).
This ADR layers the *mechanics* on top:

- **Pattern canon** (decision 1) makes the `map`-role-list shape obvious
  rather than a Perl-quirk. Future dialect bases (Gemini, Ollama,
  TranscriptionBase, AKI, LMStudio native) should use the same shape.
- **Direction-pair table** (decision 2) — a single table saying
  "OpenAI keeps X and deletes Y; Anthropic keeps Y and deletes X" is more
  useful than two near-identical code comments in two files because it
  makes the *invariant* (delete the inapplicable flag) explicit and
  generalises to future per-family corrections.
- **Explicit asymmetry** (decision 3) is cheaper than a half-done refactor.
  Naming "the generation-parameter block is duplicated because the
  dialect-aware fields around it need wire context" is the right level for
  now — a future `Langertha::Role::GenerationParams` helper becomes possible
  the day both dialect sides can hand the helper a fully resolved wire context,
  which #64 delivered (579d0c8, ADR 0013).

## Consequences

- **Cross-links.** ADR 0002 (capabilities from role inventory + the
  `around engine_capabilities` escape hatch this ADR extends). ADR 0006
  (the wire-dialect × capability split that makes `#64`-style refactors
  possible — the generation-parameter asymmetry only became safely
  *extractable* once the Anthropic wire envelope moved into a role, which
  ADR 0013 records). ADR 0009
  (request-side controls are themselves dialect-aware parameters surfaced via a
  value object — same shape as the generation-parameter block split).
- **CONTEXT.md** gets a new entry, "Request-side generation parameters
  (the per-dialect block)", placed between the existing "Request-side
  controls" and "Response-side observability" sections. The vocabulary is
  fixed without restating the rationale (link only). *Renamed 2026-08-17
  (karr #82): the entry first shipped under the audit nickname "RuntimeKnobs
  split", which collides with the real `Langertha::Role::RuntimeKnobs` (ADR
  0012) — the canonical term is now* **generation-parameter block**.
- **Comment updates** in `Engine::OpenAIBase.pm:28-33` and
  `Engine::AnthropicBase.pm:21-25` — the per-direction comments carry a pointer
  to this ADR plus a single-line reference to the partner direction. Kept out
  of this ADR's own diff to stay scoped; *done since* in karr #80 (9715189).
- **Git-native kanban.** ADR 0015 closes doku-audit findings 4 (the
  `-excludes` canon) and 6 (the per-family capability correction), and
  makes finding 5 (the generation-parameter block asymmetry) an *accepted*
  asymmetry rather than silent drift. Follow-up work:
  - karr #68 finding-1/2 implementation: update the per-direction code
    comments in `OpenAIBase.pm` / `AnthropicBase.pm` to point at this
    ADR + the partner direction. *Done* — karr #80 (9715189).
  - `Role::GenerationParams` extraction — no longer gated on #64, which
    landed in 579d0c8 and made `Langertha::Role::AnthropicCompatible` the
    stable home. Open work, not an open blocker; decision 3 names the one
    remaining precondition.
