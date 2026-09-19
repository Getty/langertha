# ADR 0023 — Per-model reasoning wire-truth is a typed Profile value object

- Status: accepted
- Date: 2026-09-16
- Tags: reasoning, value-objects, wire-format, capabilities, model-scoped

## Context

ADR 0009 made `Langertha::Reasoning` a per-format value object: `to_openai` /
`to_responses` / `to_anthropic` / `to_gemini` / `to_ollama` each **clamp** the normalized
`reasoning_effort` vocabulary to what their wire accepts and **place** it in the right body
region. But the per-model knowledge *inside* those serializers stayed untyped — ad-hoc
lookup hashes (`%OPENAI_MODEL_EFFORT`, `%ANTHROPIC_EFFORT`, `%GEMINI3_LEVEL`) and regex
predicates (`_is_gemini_25`, `_is_fable_class`, `_openai_effort_ok`) open-coded in
`Reasoning.pm`. Two concrete costs:

1. **No datatype carries what a level means.** Each new reasoning family is another table
   plus another regex, edited by hand, with nothing that says "this is what the wire accepts"
   as a first-class fact.
2. **Model-family boundaries are duplicated across three sites**, not one file: `Reasoning.pm`
   (`_is_gemini_25`), `Engine::Gemini`'s `around engine_capabilities` (the same `2.5` vs `3`
   regex, in the *capability* layer), and `Engine::DeepSeek`'s own V3.2/V4 predicate. The
   level-clamp tables were centralized in ADR 0009; the family regexes were not.

ADR 0019 already named `Reasoning::to_gemini_level` and `Reasoning::_is_fable_class` as
per-model gating living as open-coded branches — consolidation candidates alongside its
declarative `model_capability_corrections` table.

A red-team pass (advisor-verified 2026-09-16, spec §10) surfaced the linchpin fact that
reshapes the whole seam: **no major provider publishes an official reasoning-level →
token-budget mapping.** OpenAI and Anthropic effort is adaptive and undocumented; the only
numeric level→token formulas in the wild are OpenRouter's, explicitly labeled as OpenRouter's
own convention. Any level→token numbers in this library are therefore *invented*. The same
pass live-probed a second fact that breaks a standing invariant (spec §7, karr k176):
`gpt-5.6-terra` rejects `reasoning_effort=max` on Chat Completions (HTTP 400) but accepts
`reasoning.effort=max` on the Responses API (HTTP 200) — the two OpenAI wires **diverge** on
`max` for the same model, which `Reasoning.pm`'s "`to_openai`/`to_responses` share one gate
and can never diverge" comment asserted they never could.

## Decision

Per-model reasoning wire-truth is a typed, immutable Moose value object,
`Langertha::Reasoning::Profile`, resolved **most-specific-first** by
`Langertha::Reasoning::Profile->for_model($id)` (exact id → family regex → provider default,
never dies) and consumed by `Langertha::Reasoning`'s `to_*` serializers and `BUILD` gate. It
replaces the inline `%OPENAI_MODEL_EFFORT` / `%ANTHROPIC_EFFORT` / `%GEMINI3_LEVEL` hashes and
the `_is_gemini_25` / `_is_fable_class` / `_openai_effort_ok` predicates. `Reasoning` now holds
one lazy `_profile` and reads all per-model gating off it (`effort_accepted_on`,
`anthropic_effort_ok`, `gemini_level_for`, `fable_class`, `control`). Landed Phase 1 (commit
`c312baf`), **behavior-preserving** — the resolver reproduces every existing clamp exactly.

The load-bearing idea is a **three-category taxonomy with a firewall.** Reasoning knowledge
is not one thing; the original ticket's two-way split misclassified one category, and the
correction is the point of this ADR:

- **(a) Accepted vocabulary + native control type** — which levels the wire literally takes,
  and whether the control is `effort` / `budget` / `boolean` / `none`. Lives in the Profile
  (`control`, `levels`, `levels_by_wire`, `can_disable`, `disable_form`). This is the category
  that feeds the capability layer. Non-overridable: wire-truth.
- **(b) Provider-*enforced* numeric bounds & magic values** — Gemini 2.5's `thinkingBudget`
  floor/ceiling, `0`=off, `-1`=dynamic; Anthropic's per-generation `budget_tokens`
  availability. Lives in the Profile too (`budget_min`, `budget_max`, `off_value`,
  `dynamic_value`), each `source`-marked with a doc URL + verification date. **This is
  wire-truth, not convention** — an API rejects a value outside these bounds.
- **(c) Invented level↔budget interpolation** ("medium ⇒ N tokens") — no provider publishes a
  level→token table, so any such number is the library's own convention. Deferred to a
  `Langertha::Reasoning::BudgetPolicy` (Phase 2, sketch only; ships only when a consumer needs
  budget↔level conversion), clamped to the owning Profile's (b) bounds.

**The firewall rule: (c) may *read* (b) but can never *cross* it.** A curated convention must
be clamped to the Profile's enforced bounds so it can never emit a value the API rejects.
Putting (b) inside BudgetPolicy — as the original karr k173 ticket proposed — would let an
override silently violate a hard API bound. Reclassifying (b) as Profile wire-truth, out of
BudgetPolicy, is the single most important correction this design makes.

The registry is one ordered, most-specific-first table built lazily inside `Profile.pm`; each
entry carries a `source` receipt, so curating a new family is a single declarative add rather
than a new hash plus a new regex in `Reasoning.pm`. For the per-wire divergence the Profile
carries a `levels_by_wire` seam (per-wire refinement of `levels`, queried by
`effort_accepted_on($wire, $effort)`): Phase 1 populates `openai` and `responses` identically
to freeze current (shared, buggy) behavior; the `max` split is a Phase-1.5 data edit, not a
code change.

## Rationale

The value object owning both clamp and placement (ADR 0009) was right; what it lacked was a
datatype for the per-model facts it clamped against. Typing those facts turns "another family =
another table + another regex in three files" into "another declarative row with a source
receipt," and gives consumers one query surface (`for_model`) instead of scattered predicates.

**The linchpin is the (a)/(b)-vs-(c) firewall, and it exists because of provider reality, not
taste.** Advisor-verified 2026-09-16: no major provider publishes an official reasoning-level →
token-budget mapping (OpenAI/Anthropic effort is adaptive and undocumented; only OpenRouter
invents ratios, and labels them its own convention). So every level→token number is invention.
Invention that could emit an API-rejected value must be structurally prevented from crossing
wire-truth — hence the clamp-to-(b) firewall and hence (b) belongs to the Profile, never to the
convention layer.

**The per-wire seam exists because the wires demonstrably diverge.** Live-confirmed 2026-09-16
(spec §7, karr k176): `gpt-5.6` chat-completions 400s on `reasoning_effort=max` while the
Responses API accepts `reasoning.effort=max`. This refutes the old shared-gate invariant and
exposes a latent bug — the current `gpt-5.6` set includes `max` and is applied to *both* wires,
so `to_openai` emits a live-400 value. `levels_by_wire` is the shape that lets `to_openai` and
`to_responses` resolve different accepted sets; freezing them identical in Phase 1 keeps the
transform pure and characterization-locked (`t/47_openai_reasoning.t` stays green), and the
`max` split lands as a Phase-1.5 data edit citing that probe.

## Consequences

- **A new reasoning family** = one declarative Profile row (matcher, `control`, `levels`,
  optional (b) bounds, `source`), resolved by `for_model`, instead of a hash entry plus a regex
  predicate in `Reasoning.pm`. The `BUILD` budget-vs-effort gate now derives from
  `profile->control` (Gemini 2.5 is the only `control=budget` family today), so the family
  boundary is declarative, not an inline `_is_gemini_25` regex.
- **The capability layer was deliberately left untouched (relates ADR 0002).** The per-model
  level *subset* the Profile carries is finer than today's coarse `supports('reasoning_effort')`
  boolean, and is **not** projected into `engine_capabilities` — YAGNI: the Profile registry is
  queried directly for "which levels does model X accept," so wiring capability↔profile waits
  for a consumer that actually reads it. `thinking_budget` stays a dynamic flag set inside
  `Engine::Gemini`'s `around engine_capabilities` (it is **not** in `%ROLE_TO_CAPS`; a refactor
  that regenerated caps from the role registry would silently drop it and redden
  `t/65c_vllm_reasoning.t` / `t/78_engine_capabilities.t`). This is a **deliberate keep**, not
  an omission.
- **Acknowledged remaining drift, surfaced honestly:** `Engine::Gemini`'s `around
  engine_capabilities` still carries its own inline `/\Agemini-2\.5/` and `/\Agemini-3/`
  regexes. The family boundary is now declarative in the Profile for the *serialization* layer,
  but the *capability* layer was intentionally not migrated in Phase 1. This is a **candidate**
  future reconciliation — not a decided one, and it is the same consolidation ADR 0019 already
  parked for Gemini.
- **The ADR 0009 quartet is intact.** This decision types the per-model knowledge *inside* the
  reasoning value object; the role + value object + `reasoning_wire_format` tag + capability
  flag structure is unchanged. The ADR-0009 Update (`output_config` shared by two concerns via
  `_merge_output_config_format`) is **unaffected** — reasoning-effort placement did not move.
- **Ollama's direct construction path** (`Engine::Ollama`, which bypasses
  `Role::ReasoningEffort`) is pulled through the same Profile, so the boolean `options.think`
  collapse is now the `ollama` profile's `control=boolean` fact rather than a hand-coded branch.

## Future work

Phase 1.5 fixes are declarative Profile/`levels_by_wire` edits, each flipping exactly one
characterization assertion against a cited doc source — never folded into the behavior-preserving
refactor:

- **karr k176** — the OpenAI `max` per-wire split (chat drops `max`, responses keeps it) for the
  gpt-5.6 / gpt-6 generations, citing the live probe.
- **karr k174** — gate `gpt-5.1` (drop `minimal`/`xhigh`/`max`), with `gpt-5.1-codex-max` as a
  most-specific-first carve-out that re-adds `xhigh`.
- **karr k175** — Ollama level strings (`low`/`medium`/`high`/`max`) with GPT-OSS as a
  level-only discriminator, replacing the model-agnostic boolean.

Deferred beyond Phase 1.5:

- ~~**Phase 2 — `Langertha::Reasoning::BudgetPolicy`**~~ **— realized (k178).** See the closing
  Update. Category (c) + the inbound budget↔level bijection now ship as a real class; still
  consumer-driven and not default-shipped; every numeric output clamped to the owning Profile's (b)
  bounds (the firewall, enforced in code).
- **Gemini capability-layer consolidation** — migrate `Engine::Gemini`'s inline model-regex
  `around` into the declarative form. A candidate, not a defect; kin to the Gemini consolidation
  bullet in ADR 0019's *Future work*.

## Cross-links

- **Amends ADR 0009** — 0009 made `Langertha::Reasoning` a per-format value object with inline
  clamping + placement; this ADR types the per-model knowledge inside it into a Profile registry,
  keeping the per-concern wire-format quartet (role + value object + `reasoning_wire_format` tag +
  capability flag) intact. The 0009 `output_config`-sharing Update is unaffected.
- **Nuances ADR 0019** — 0019 named `Reasoning::to_gemini_level` / `_is_fable_class` as per-model
  gating living as open-coded branches; those now derive from the one declarative Profile table.
  The Gemini *capability*-layer `around` remains the un-migrated consolidation candidate 0019
  already flagged.
- **Relates ADR 0002** — the capability boundary above: the per-model level subset is finer than
  the role-derived `reasoning_effort` boolean and is deliberately not projected into
  `engine_capabilities`; `thinking_budget` stays a dynamic `around` flag outside `%ROLE_TO_CAPS`.
- Ground truth: the design spec
  `docs/superpowers/specs/2026-09-16-reasoning-profile-design.md`; Phase 1 commit `c312baf`;
  karr k173 (this decision). `CONTEXT.md`'s `reasoning_wire_format` / `Langertha::Reasoning` entry
  carries the vocabulary this ADR builds on (not restated here).

## Update (k178 — Phase 2 `BudgetPolicy` realized; the firewall is now enforced in code)

The deferred **Phase 2** category-(c) layer now exists as `Langertha::Reasoning::BudgetPolicy`
(`lib/Langertha/Reasoning/BudgetPolicy.pm`, k178) — the invented level↔token-budget interpolation and
its inbound inverse, with **the (a)/(b)-vs-(c) firewall enforced in code**, not merely asserted in the
design:

- **The firewall is a real clamp.** `_clamp` (`BudgetPolicy.pm:205`) pins every number to the owning
  Profile's category-(b) bounds (`profile->budget_min` / `budget_max`), and both directions run
  through it: `budget_for($level)` (`:250`) clamps its **output**, and `level_for($budget)` (`:299`)
  clamps its **input** before mapping it back to a level (a budget equal to the Profile's `off_value`
  maps to `none`). So category (c) may *read* the (b) bounds but can never emit a value the API
  rejects — the single most important correction this ADR made, now structural.
- **It is not a capability and is not default-shipped.** Nothing in Langertha wires it in; it exists
  only where a downstream consumer needs budget↔level conversion and constructs it explicitly
  (`for_model($id, %opts)` `:343`, mirroring the Profile constructor). It offers both an `explicit`
  form (curated `points` anchors) and a `range` form (a `linear`/`log` curve across the Profile's (b)
  bounds); the `source` receipt defaults to a string that says the numbers are **library convention,
  not wire-truth**. Category (a)/(b) stay in the Profile (its `levels` is empty for a budget control,
  keeping it pure wire-truth); the convention anchors live on the policy.
- This closes the ADR-0023 Phase-2 Future-work item; it does **not** change the Profile, the capability
  layer, or the ADR 0009 quartet. Verified offline: `t/48_reasoning_budget_policy.t` (firewall +
  bijection coverage).

## Update (k180 — self-hosted reasoning vocabulary is a Profile registry dimension)

Self-hosted engines (`vLLM` / `SGLang` / `llama.cpp`) get their accepted `reasoning_effort`
vocabulary from the **loaded model's chat template, not the server** — so the vocabulary is keyed
**per model-family**, exactly the category-(a) fact the Profile registry already types. k180 registers
the first such family without touching any code path:

- **Qwen3.x** is a declarative Profile row (`Profile.pm:490`, matcher `qr{(?:\A|/)qwen3\.\d}i` — with
  or without the HuggingFace `org/` prefix, since served ids look like `Qwen/Qwen3.8-27B-FP8`),
  `control => 'effort'`, `wire_format => 'openai'` (the sole wire these engines speak), accepting
  **`none|low|medium|xhigh`** and **dropping `high` and `minimal`** — live-probed 2026-09-17 on a
  cortex vLLM server (`Qwen/Qwen3.8-27B-FP8` 400s on `reasoning_effort=high`), receipt in
  `$QWEN_SELFHOSTED_SRC` (`Profile.pm:383`). The two rejected efforts drop before they can 400 the
  server.
- **Unknown self-hosted ids are deliberately *not* listed.** They fall through to the passthrough
  default and keep going **raw** — the correct posture for an unknown chat template ("correct the wire
  reality you can verify; don't invent one you can't"), consistent with the whole ADR-0023 stance.
- This is a new *dimension* of the same category-(a) registry, not a new mechanism: no capability
  wiring, no serializer change. Verified offline: `t/48_reasoning_profile.t` (the Qwen self-hosted
  matrix).
