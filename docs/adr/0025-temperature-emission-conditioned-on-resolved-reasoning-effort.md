# ADR 0025 — Temperature's wire emission is conditioned on the resolved reasoning effort (OpenAI reasoning models)

- Status: accepted
- Date: 2026-09-19
- Tags: reasoning, temperature, wire-format, capabilities, chat_f, model-scoped

## Context

OpenAI reasoning models (the o-series, the gpt-5 line except the non-reasoning `gpt-5-chat`, and
gpt-6) return **HTTP 400 on a non-default `temperature` while reasoning is active** — *"'temperature'
does not support 0.7 with this model. Only the default (1) value is supported"* (live-verified
2026-09-17 on `gpt-5.6-terra` + `gpt-5.6` against `/v1/chat/completions`). This is neither a flat
per-model capability nor a static wire fact:

- **It is effort-aware.** At `reasoning_effort=none` — where these models actually accept disabling
  reasoning — the *same* call returns 200 with the non-default temperature. So clearing the
  `temperature` capability wholesale (ADR 0002 / ADR 0019) would wrongly drop the valid `effort=none`
  path.
- **It fires on the no-effort path too**, because when the caller sets no effort the model's
  **server-side default effort** (medium) applies — reasoning is on — so the predicate must resolve
  the effort *including* that default.

`temperature` and `reasoning_effort` are two ADR 0009 quartet concerns. ADR 0009 placed each
concern's field in a **disjoint body key**, and the k133 Update recorded the first break of that
disjointness — two concerns *sharing* the `output_config` key. k155 is a **different** kind of
cross-concern interaction: not two concerns sharing a key, but **one concern's emission gated by
another concern's resolved value.** That is a new interaction the quartet had not yet had.

## Decision

Condition `temperature`'s wire emission on the resolved reasoning effort, in two pieces:

1. **A shared `_temperature_kwargs($controls)` gate in the OpenAI wire roles**
   (`Role::OpenAICompatible.pm:314`, `Role::ResponsesCompatible.pm:109`), which **all four OpenAI
   wire sites route through** (chat + stream on each role, replacing four copies of the inline
   `exists $controls->{temperature} ? … : has_temperature ? …` ternary). It mirrors
   `AnthropicCompatible::_temperature_kwargs` — the `supports('temperature')` check plus
   control-beats-attribute resolution — and adds the effort-aware drop: **only** a non-default value
   (`temp != 1`) under active reasoning is dropped, with a `carp` that names the escape hatch
   (`reasoning_effort => 'none'`). `temperature=1` passes through **silently** (dropping the wire
   default would be a pure-noise warning).

2. **An effort-aware, model-aware predicate `_temperature_rejected_by_reasoning($controls)` on
   `Engine::OpenAI`** (`OpenAI.pm:126`), consumed **read-only** by the gate via `can()`. The predicate:
   - **(a)** gates on the per-engine reasoning-model regex (`o\d` / `gpt-5` except `-chat` / `gpt-6`)
     — the ADR 0019 per-engine model list;
   - **(b)** resolves the effort control-beats-attribute, treating **unset as the server-side
     default** (reasoning on); and
   - **(c)** counts a `none` effort as "reasoning off" **only where the model's wire actually accepts
     `none` as the disable value** — a *read-only* consult of
     `Langertha::Reasoning::Profile->for_model($model)->effort_accepted_on($wire, 'none')` (ADR 0023,
     the same effort table the serializer uses). A model that cannot be disabled (gpt-6) drops a
     `none` effort server-side and keeps reasoning on, so temperature stays rejected there.

   `OpenAIResponses` inherits the predicate and runs it on the `responses` wire; every **other**
   OpenAI-compatible engine (and Perplexity, the other Responses consumer) never defines the
   predicate, so the `can()` guard leaves their temperature untouched.

## Rationale

- **A runtime predicate, not a static capability clear** (deliberately, cf. ADR 0019). A static clear
  cannot see the per-request `effort=none` escape — it would drop a temperature the model would have
  accepted. The rejection is a function of *this request's* resolved effort, so the check has to run
  per call.
- **The `temperature` capability is deliberately NOT cleared** — a *deliberate keep* (ADR 0002).
  Temperature is genuinely valid on these models at `effort=none`, so the capability is honestly
  present; the gate is a per-request emission decision, not a capability fact.
- **Drop + carp, not croak** (contrast ADR 0021). Temperature is an advisory sampling knob; dropping
  it under active reasoning loses nothing the caller actually needs — the reasoning answer is the
  point, and the wire default (1) is what the model uses anyway. So the request proceeds and the
  caller is warned, with the escape hatch named. ADR 0021 croaks instead because there *both*
  conflicting fields carry essential intent (dropping either discards half the request); here the
  dropped field is recoverable and non-essential.
- **The predicate reads the Profile read-only** (ADR 0023): effort wire-truth has exactly one home,
  and this gate consults it rather than re-encoding "which models accept `none`."

## Consequences

- **A new interaction category in the ADR 0009 quartet:** control-on-control conditioning — one
  concern's emission gated by another concern's *resolved* value (including a server-side default).
  Distinct from the k133 `output_config` key-sharing case; recorded so the next such interaction has
  a precedent.
- **Blast radius is exactly OpenAI reasoning models.** Non-reasoning OpenAI models (`gpt-4o`,
  `gpt-5-chat`) and every other OpenAI-compatible / Anthropic / Gemini engine never define the
  predicate, so the `can()` guard is a no-op for them and their temperature is unchanged.
- **The four wire sites now share one gate**, so the Anthropic and OpenAI `_temperature_kwargs`
  gates read as siblings (same `supports` + control-beats-attribute skeleton, different provider
  quirk bolted on).
- **Verified offline** (no live calls): `t/79_openai_temperature_reasoning_gate.t` covers both wires,
  the streaming path, and the drop/carp rule; `t/60_responses_requests.t` keeps its temperature
  assertion valid by pinning `reasoning_effort => 'none'`.

## Cross-links

- **Extends ADR 0009** — the request-side control quartet gains its first *control-on-control*
  conditioning, distinct from (and additional to) the k133 `output_config` key-sharing break.
- **Consumes ADR 0023** — reads `Langertha::Reasoning::Profile::effort_accepted_on` read-only to know
  where `none` truly disables reasoning.
- **Relates ADR 0019** — kept a runtime predicate rather than a static, per-model capability clear,
  because a static clear cannot see the per-request `effort=none` escape.
- **Relates ADR 0002** — the `temperature` capability is deliberately *not* cleared (valid at
  `effort=none`); this is a per-request emission gate, not a capability correction.
- **Contrast ADR 0021** — same "a relationship a boolean can't spell, resolved above the registry"
  shape, but drop-and-warn here vs. croak there, because temperature is recoverable where the
  ADR 0021 pair is not.
