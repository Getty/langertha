# Design Spec — Provider server-side tools (`Langertha::ServerTool`) and `Engine::XAIResponses` (karr k206)

- Status: **proposed** (spec only, nothing implemented)
- Date: 2026-09-25
- karr: k206 (this). Related: k208 (grok `Reasoning::Profile` row, parallel branch), k205 (XAI default model, parallel branch)
- ADRs read: **0001**, **0002**, **0003**, **0004**, **0005**, **0010**, **0016**, **0018**, **0019**, **0020**, **0024**, **0029**, `CONTEXT.md`
- ADRs touched when implemented: new ADR (next free number, **re-check at merge**; parallel branches allocate independently), `## Update` on **0003** and **0029**, new terms in `CONTEXT.md`
- Provider facts: from the k206 llm-advisor note (docs fetched 2026-09-25) plus the current code.
  Anything else is marked **[verify: llm-advisor]** and must be confirmed before Phase 1 code.

## 1. Problem

Langertha has no seam for provider-hosted ("server-side") tools, the tools the provider
runs itself during one request: web search, X search, code interpreter, file/collection
search, remote MCP. xAI offers these only on `/v1/responses` (advisor, k206), so an
`Engine::XAIResponses` without this seam gives users nothing that `Engine::XAI` doesn't already
give them. `OpenAIResponses` users lack OpenAI's hosted tools for the same reason.

What the code does today, verified in the k206 worktree (not the same as the ticket's
"nameless function tool"):

| Input | Path | Result |
|---|---|---|
| `{type=>'web_search'}` | `Tool->from_hash` → `from_anthropic` | `undef`, so `from_list`/`format_list` **silently drop** it |
| `{type=>'web_search_20250305', name=>'web_search'}` (Anthropic shape) | `Tool->from_hash` → `from_anthropic` | a **user function tool** called `web_search` with an empty schema. The server-tool `type` is lost, which is a silent corruption |
| `chat_f(tools=>[{type=>'web_search'}, $mcp_tool])` on `OpenAIResponses` | `ResponsesCompatible::chat_request` formats only when `$tools[0]` has no `type` | whole list goes out **verbatim**, and the MCP-shaped tool reaches the wire unformatted (400) |
| `chat_f(tools=>[$mcp_tool, {type=>'web_search'}])` on `OpenAIResponses` | same heuristic, first item has no `type` | `format_list` runs, and web_search is **silently dropped** |
| `chat_f(tools=>[{type=>…}])` on `OpenAI` / `Anthropic` / `Gemini` | those `chat_request`s pass `tools` verbatim | reaches the wire as written, so a de facto raw escape hatch already exists on `chat_f` |
| `chat_with_tools_f` | tools come only from `mcp_servers` → `format_tools` | no way to add a server tool at all |

Inbound, nothing breaks but everything is lost. `ToolCall->locate` only matches
`function_call` / `tool_use` / `functionCall`, so server-side call items are already
excluded from `Response.tool_calls` (good, see §3.2). But their results, the
`url_citation` annotations and server-tool usage are dropped, except Perplexity's
`search_results` (lifted into `Response.citations` by its `_responses_extra_fields`).

Side finding, to fix in Phase 1 because xAI hits it on every reasoning reply:
`ResponsesCompatible::chat_response` reads `$item->{summary}[0]{text}` as a chained
rvalue. A `reasoning` item with `summary => []` or no `summary` gets `summary => [{}]`
autovivified into `raw` (verified with perl). This is the k168 bug class. xAI always
returns `reasoning.encrypted_content` with no summary (advisor), so every xAI reply
would carry the polluted trace.

## 2. Inventory

"Built-in" is not the same as "server-side". Several providers ship built-in tools that
the **client** executes (Anthropic `bash`/`text_editor`/`computer`/`memory`, OpenAI
`computer_use_preview`/`local_shell`/`shell`/`apply_patch` **[verify: llm-advisor]**). This
spec covers only tools the **provider** executes, meaning the client never runs the call.

### 2.1 OpenAI Responses (`/v1/responses`, `tool_wire_format` `responses`)

- **Request:** entries in the same `tools` array as function tools, discriminated by
  `type`, e.g. `{type:"web_search"}` (earlier `web_search_preview`),
  `{type:"file_search", vector_store_ids:[…]}`, `{type:"code_interpreter", container:{…}}`,
  `{type:"image_generation"}`, `{type:"mcp", server_label, server_url, require_approval}`
  **[verify: llm-advisor — current type names, versions, per-model availability]**. On
  this wire, anything whose `type` is not `function` is a built-in.
- **Response:** typed `output[]` items next to `message` / `function_call`:
  `web_search_call` (`id`, `status`, `action`), `file_search_call`,
  `code_interpreter_call`, `image_generation_call`, `mcp_list_tools`, `mcp_call`,
  `mcp_approval_request`. Citations come as `output_text.annotations[]` of
  `type:"url_citation"` (`url`, `title`, `start_index`, `end_index`) and `file_citation`
  **[verify: llm-advisor — item + annotation shapes]**.
- `mcp_approval_request` needs a **client round-trip** (an approval input item). That makes
  it neither a pure server call nor a function call; see the open questions (§8).
- `tool_choice` can force a hosted tool (`{type:"web_search"}`)
  **[verify: llm-advisor]**. Today `ToolChoice->from_hash({type=>'web_search'})` returns `undef`.

### 2.2 xAI Responses (`https://api.x.ai/v1/responses`)

From the advisor note (2026-09-25, docs only, no live call):

- Server-side agentic tools `web_search`, `x_search`, `code_interpreter`,
  collections/`file_search` and remote MCP exist **only** on `/v1/responses`. Chat
  Completions is "function calling only". Live Search `search_parameters` answers HTTP 410
  since 2026-01-12.
- Also Responses-only: `grok-4.20-multi-agent`, `previous_response_id`/`store`, `max_turns`,
  the encrypted reasoning round-trip (grok-4.7 always returns `reasoning.encrypted_content`),
  citations/annotations, and reasoning-summary stream events.
- Not Responses-only: `reasoning_effort`, `prompt_cache_key`, json_schema, function tools,
  streaming, `reasoning_content`.
- **Request:** same Open-Responses `tools[]` shape, keyed by `type`
  **[verify: llm-advisor — exact type strings, MCP tool fields, collections field names]**.
- **Response:** a top-level `citations` array (advisor) plus output items for the server
  calls **[verify: llm-advisor — item type names, whether `citations` holds URL strings
  or objects, whether `output_text.annotations` is also populated, the server-tool usage
  block (e.g. `server_side_tool_usage`)]**. The output walker already skips unknown item
  types.

### 2.3 Anthropic Messages (`tool_wire_format` `anthropic`), Phase 2

- **Request:** entries in `tools[]` carry a dated `type` plus a fixed `name`:
  `{type:"web_search_20250305", name:"web_search", max_uses, allowed_domains, …}`,
  `web_fetch_…`, `code_execution_…` (possibly with a beta header)
  **[verify: llm-advisor — current versions and beta headers]**. User tools have no
  `type` (or `type:"custom"`). The Anthropic-defined **client** tools (`bash_…`,
  `text_editor_…`, `computer_…`, `memory_…`) use the same dated-`type` shape but come back
  as ordinary `tool_use` blocks, so the shape alone does not say who executes.
- **Response:** `server_tool_use` blocks (`id`, `name`, `input`) plus result blocks
  (`web_search_tool_result`, `code_execution_tool_result`, … with `tool_use_id`). `text`
  blocks carry `citations[]` (`web_search_result_location`: `url`, `title`, `cited_text`).
  `usage.server_tool_use.web_search_requests` counts calls. `stop_reason:"pause_turn"`
  means a long server turn was paused and must be re-sent to continue.
- The MCP connector is a top-level `mcp_servers` body field (beta), with
  `mcp_tool_use`/`mcp_tool_result` blocks **[verify: llm-advisor]**. It has the same name
  as Langertha's `mcp_servers` attribute (client-side MCP) and a different meaning. A
  `chat_f(mcp_servers=>…)` kwarg would reach the wire through `%extra`.

### 2.4 Gemini (`tool_wire_format` `gemini`), Phase 2

- **Request:** sibling entries in `tools[]` next to the `{functionDeclarations:[…]}` entry:
  `{google_search:{}}`, `{code_execution:{}}`, `{url_context:{}}`, possibly
  `{google_maps:{}}` / file search **[verify: llm-advisor]**. Whether `google_search` and
  `functionDeclarations` may be combined in one request depends on the model
  **[verify: llm-advisor]**. Where they cannot, that is an ADR 0024 model-scoped exclusion,
  not a flag.
- **Response:** `candidates[0].groundingMetadata` (`webSearchQueries`,
  `groundingChunks[].web.{uri,title}`, `groundingSupports`). Code execution returns
  `executableCode` / `codeExecutionResult` parts inside `content.parts`.

### 2.5 Perplexity Agent API (`/v1/agent`)

Search is implicit in the preset. Results already reach `Response.citations` via
`search_results`. Whether the Agent API accepts explicit `tools:[{type:"web_search"},
{type:"fetch_url"}]` is **[verify: llm-advisor]**. Perplexity composes no `Role::Tools`
(ADR 0005/0010), so the seam below must not depend on `Role::Tools`.

### 2.6 Out of scope, named so nobody assumes coverage

- Groq "compound" models (server tools on `chat/completions`, `executed_tools` in the message)
- OpenRouter `plugins`/`:online`
- Mistral Agents/Conversations connectors
- OpenAI Chat Completions `web_search_options`

These are body fields, not `tools[]` entries, so they already fit ADR 0004 top-level
`%extra` and need no seam.

## 3. The value-object seam

### 3.1 Options

**(a) A kind flag on `Langertha::Tool`** (`kind => 'server'`, plus a native passthrough hash)

- **ADR 0001:** it stays inside the seam, but it bends the definition. A `Tool` is the
  canonical definition that every wire can translate (`to($fmt)` total over
  `%TO_METHOD`). A server tool cannot be translated at all: `web_search` on Responses,
  `web_search_20250305` on Anthropic and `google_search` on Gemini are three different
  contracts. So `to`, `to_json_schema` (the forced-tool rewrite, ADR 0005), `to_mcp`/hermes
  and `to_hash` would each need a `kind` branch and a croak.
- **Types:** `name` is `required` and `input_schema` defaults to an object schema. OpenAI
  server tools have neither, so both invariants go soft.
- **Risk:** every existing `Tool` consumer, including siblings (Raider builds `Tool`s),
  would have to learn to skip the kind.
- **Rejected:** it makes the most-used value object partial in order to carry something it
  cannot translate.

**(b) A separate `Langertha::ServerTool` value object** — recommended

- **ADR 0001:** it fits the house pattern exactly. The seam is a *family* of value objects
  keyed by one tag (`Tool`, `ToolCall`, `ToolResult`, `ToolChoice`, ADR 0010), and
  `ServerTool` becomes the fifth member, dispatched on the same `tool_wire_format`. Engines
  still carry no per-format code.
- **Contract:** its `to($fmt)` is honest. It returns the native spec on the wire it
  belongs to and croaks on any other, which is fail-loud where (a) would be quietly partial.
- **Types:** `Tool` keeps `name` required and total translation.
- **Rules:** recognizing a raw hash is **format-pinned** (`ServerTool->from_hash($fmt,
  $hash)`), like `ToolCall->extract($fmt, …)`, never sniffed. The per-wire rule is simple:
  - `responses`: `type` present and ne `function`;
  - `anthropic`: `type` present and not `custom`;
  - `gemini`: a key other than `functionDeclarations`.
- **Cost:** one more class, and a partition step in `Tool->format_list`.

**(c) A raw escape hatch** (`raw_tools => [...]` appended verbatim, or `%extra` `tools`)

- **Status:** it already exists by accident on `chat_f` for the OpenAI, Anthropic and
  Gemini `chat_request`s (§1).
- **ADR 0004:** not an `extra_body` violation as such (it's a top-level kwarg), but it is
  the *shape* 0004 rejects: an open, unreviewed bucket.
- **Other costs:** no capability check, no fail-loud on a wrong wire, no mixing with MCP
  tools (the Responses heuristic breaks mixed lists either way), and nothing for
  `chat_with_tools_f`.
- **Rejected as the design.** The existing verbatim path on `chat_f` stays as it is
  (deliberate keep: removing it would break callers who pass provider-shaped tools today).

### 3.2 ADR 0003 — do server-side calls belong on `Response.tool_calls`?

**No.** `tool_calls` has one operational meaning to every consumer:

- `chat_with_tools_f` dispatches each call to `mcp_servers` by name, and dies with
  "Tool '…' not found" on a miss;
- Raider does the same;
- a `chat_f` caller acts on them.

`synthetic` records *provenance*. It does not say "don't execute". If server calls went on
`tool_calls`, every consumer, siblings included, would have to filter them, and missing
the filter crashes the loop. The client never executes a server call, so it is not a
tool call in 0003's sense. It is a record of what the provider did.

Therefore:

1. **Invariant (made explicit and tested):** `ToolCall->locate($fmt, …)` never returns a
   server-side call item. That holds today on every wire. A regression test pins it per
   wire with the captures in §6.
2. **New `Response` attribute `server_tool_calls`** (ADR 0004: first-class, `Maybe`-typed,
   predicate `has_server_tool_calls`, in the `clone_with` copy list):
   `ArrayRef[Langertha::ServerToolCall]`. `ServerToolCall` is a thin immutable record:
   `type` (the wire item type, e.g. `web_search_call`, `server_tool_use`), `id`, `status`
   (optional), and `data` (the item verbatim). Cross-provider normalization of
   inputs/outputs is **not** done in Phase 1. The shapes differ too much, and a guessed
   canonical form would be the invented-value trap of ADR 0023. `to_hash`/`TO_JSON` as
   on `ToolCall`.
3. **Citations** go to the existing `Response.citations`, as HashRefs with at least `url`
   (plus `title` / `snippet` when present). Deduplicate by `url`, keeping first-seen order.
4. ADR 0003 gets an `## Update (k206)`: `tool_calls` means **calls the client must act
   on**; provider-executed activity is recorded on `server_tool_calls` and is not a
   second tool-call representation.

### 3.3 `chat_with_tools_f` must not execute server calls

It doesn't need to change for this. It already sees only `ToolCall->locate` output, and the
invariant above keeps server items out. The server items still travel in the **assistant
echo**, because the `responses`, `anthropic` and `gemini` branches of
`format_tool_results` echo the whole `output[]` / `content` / `parts`, so the provider keeps
its context. When a turn has only server activity and final text, the loop returns that
text, which is correct.

The one open loop behavior is Anthropic `pause_turn` (Phase 2, §5).

### 3.4 How users hand server tools over

- **Per request:** `chat_f(tools => [ … ])` accepts a mix of MCP hashes, provider-shaped
  function hashes, `Langertha::Tool`, `Langertha::ServerTool` objects and raw server-tool
  hashes. For engines with the capability, the envelope normalizes the list with
  `Tool->format_list($fmt, …)`, which now partitions each item:
  - a blessed `ServerTool` → `->to($fmt)`;
  - `ServerTool->from_hash($fmt, $h)` recognizes it → verbatim;
  - anything else → `Tool->from_hash` → `to($fmt)`.

  Per-item formatting replaces the "`$tools[0]` has no `type`" heuristic in
  `ResponsesCompatible::chat_request`. That fixes both mixed-list failures in §1 and the
  chat-completions-shaped `{type:function, function:{…}}` hash, which is currently sent
  verbatim to a flat-tool wire.
- **Per engine:** a new capability role `Langertha::Role::ServerTools` (ADR 0016: capability
  roles are roles from day one) with attribute `server_tools` (ArrayRef of `ServerTool` or
  raw hashes, `default => sub { [] }`). The envelope's `chat_request` / `chat_stream_request`
  append them to every request's `tools`. So `simple_chat` and `chat_with_tools_f` get web
  search without the loop changing.
  - The role does **not** require `Role::Tools`: a server-tools-only engine (Perplexity,
    if §2.5 verifies) stays possible.
- **Constructors:**
  - `ServerTool->new(wire => 'responses', spec => { type => 'web_search' })`;
  - `ServerTool->from_hash($fmt, $hash)`, which returns `undef` when the hash is not a
    server tool on that wire.
- **Values are open** (ADR 0029 stance): Langertha keeps no list of valid `type` strings,
  so a new provider tool works without a release.
- **Client-executed built-ins** (§2 intro) croak in `ServerTool->from_hash` / `new` with a
  pointer ("client-executed built-in; not a server tool"). That needs a small **denylist**,
  which is safer than a positive list: an unknown type passes, and only the known
  loop-breakers are refused. Otherwise their calls would slip past the loop:
  - Anthropic's become `tool_use`, and the loop dies on "not found";
  - OpenAI's become an unknown item type, and the loop silently ends.
- **Fail loud:** a `ServerTool` (object or recognized hash) reaching an engine without
  `supports('server_tools')` croaks in `chat_f` / the envelope before the request, and a
  `ServerTool` whose `wire` differs from the engine's `tool_wire_format` croaks in `to`.
  Raw unrecognized hashes on non-supporting engines keep today's verbatim behavior
  (the deliberate keep in §3.1c).

### 3.5 Recommendation

Option **(b)**: `Langertha::ServerTool` (outbound, native passthrough, pinned to one wire),
`Langertha::ServerToolCall` + `Response.server_tool_calls` (inbound record), citations on
the existing `Response.citations`, the capability role `Role::ServerTools` and a
`server_tools` flag. `Response.tool_calls` stays client-actionable only (ADR 0003 update).

## 4. Capability registry (ADR 0002) and manifest (ADR 0029)

- **One flag, `server_tools`**, contributed by `Role::ServerTools` in `%ROLE_TO_CAPS`.
  Meaning, per ADR 0002: *the wire accepts provider-native server-side tool entries in
  `tools`*, not that every model honors every tool type.
- **Per-tool-name flags rejected:**
  - they would need a closed vocabulary of provider tool names;
  - they drift monthly (Anthropic's dated types);
  - they collide with the "values open" stance.
- **Per-model reality** (a model that rejects hosted tools, e.g. a multi-agent or pro SKU)
  goes into `model_capability_corrections` (ADR 0019 layer 3), never into a layer-2 regex.
  Candidate rows: **[verify: llm-advisor]**.
- **Pairwise conflicts** (e.g. Gemini `google_search` + `functionDeclarations`, if
  model-dependent) go through `model_capability_exclusions` (ADR 0024). That needs a
  `has_server_tools` argument next to `has_tools`: a Phase 2 extension of the exclusion
  call signature.
- `t/78_capability_registry.t`: `Role::ServerTools` appears in the map, so the axis test
  passes without an allowlist entry.
- **Manifest (ADR 0029):**
  - Add `server_tools` to `@MODEL_CAPABILITIES`. It describes a chat call to that model at
    that endpoint, so it qualifies, and the Builder guard test forces the classification.
  - Values are evaluated per model via the existing clone, so layer-3 corrections apply.
  - **Known v1 limitation**, added to 0029's list: the manifest says *that* server tools
    are accepted, not *which* types. Publishing types would be a later `extensions` or
    schema-v2 decision. Record this as an `## Update (k206)` on 0029.
- **Builder dialect:** `XAIResponses` isa `XAI` isa `OpenAIBase`, so `@DIALECT_BY_CLASS`
  would call it `openai-chat`, which is wrong. Add
  `[ 'Langertha::Engine::XAIResponses' => 'responses' ]` above the `OpenAIBase` row. Same
  envelope, same client adapter, so no new dialect is needed. More generally, a row keyed on
  "does the engine compose `Role::ResponsesCompatible`" would stop the next Responses
  engine from repeating this. That is a small Builder decision for the implementer to
  flag, not to make silently.

## 5. `Engine::XAIResponses` sketch (from the advisor's note, adjusted)

```perl
package Langertha::Engine::XAIResponses;
# ABSTRACT: xAI Grok via the Responses API (server-side tools, multi-agent)
use Moose;
extends 'Langertha::Engine::XAI';
with 'Langertha::Role::ResponsesCompatible', 'Langertha::Role::ServerTools';
sub _build_supported_operations { [qw( createResponse )] }
sub _responses_extra_fields { ... }   # top-level citations -> Response.citations
__PACKAGE__->meta->make_immutable;
```

- **Inherited from `XAI`:** URL `https://api.x.ai/v1`, `LANGERTHA_XAI_API_KEY`, Bearer
  auth, default model, `/models`. This is the same shape as `OpenAIResponses` on `OpenAI`.
  `ResponsesCompatible` in the subclass overrides the inherited `_build_tool_wire_format` /
  `_build_reasoning_wire_format` (→ `responses`) and `chat_request` / `chat_response`.
- **Hooks (ADR 0020):**
  - `_responses_model_kwargs`, `_responses_format_kwargs` (`text.format`, which the xAI ref
    has), `_responses_dispatch` (`createResponse`) and `_normalize_input_item` keep their
    defaults.
  - `_responses_dispatch` needs `supported_operations` = `createResponse`, because `XAI`
    restricts it to `createChatCompletion`.
  - `_responses_extra_fields` lifts xAI's top-level `citations` (normalized to
    `{ url => … }` hashes if they are bare strings **[verify]**). It is also used on the
    final stream chunk (the existing k158 path).
- **Streaming stays on**, unlike `OpenAIResponses`. xAI streams typed SSE. Whether its event
  names match `parse_stream_chunk` (`response.output_text.delta`, `response.completed`) is
  **[verify: capture]**. Server-tool and reasoning-summary events fall through to `undef`,
  which is correct.
- **Encrypted reasoning:** fix the `summary[0]{text}` autovivification (§1). An
  `encrypted_content`-only reasoning item must yield no `thinking` (undef, not `''`). The
  `responses` assistant echo already carries the reasoning item back, which is what the
  round-trip needs in a tool loop. Whether a stateless multi-turn call needs
  `include => ['reasoning.encrypted_content']` is **[verify: llm-advisor]**. If it does,
  send it as a top-level kwarg (ADR 0004).
- **Reasoning / temperature:**
  - `reasoning_wire_format` `responses` emits `reasoning:{effort}`. Which grok models accept
    it on Responses belongs to the grok `Reasoning::Profile` row, **k208 on the parallel
    branch**. This spec does not touch `Reasoning/Profile.pm` or `Engine/XAI.pm`.
  - `_temperature_rejected_by_reasoning` is not defined on `XAI`, so the `can()` guard in
    `_temperature_kwargs` passes temperature through. Whether grok reasoning models reject
    it is **[verify: llm-advisor]** (k208 territory).
- **Capabilities:**
  - inherited: `tools_native`, `tool_choice_*`, `response_format_json_schema`, `streaming`;
  - added by the role: `server_tools`;
  - `response_format_json_object` on xAI Responses is **[verify]**;
  - `grok-4.20-multi-agent` is Responses-only, so there is no correction on this engine;
    whether it accepts client function tools is **[verify]**.
- **Out of scope:** `previous_response_id`/`store`, `max_turns` (both reachable as
  top-level kwargs today, ADR 0004).
- **Done-list (langertha-internals):**
  - `t/00_load.t`, `t/10_engine_hierarchy.t`;
  - the `lib/Langertha.pm` catalogue (`t/79`) and the `CLAUDE.md` engine tree;
  - the Builder dialect row (§4);
  - POD pointing at `Engine::XAI` for function-tool-only use.

## 6. Phasing and test strategy

### Phase 1 — the seam, OpenAIResponses, XAIResponses

1. `Langertha::ServerTool` (`new`, `from_hash($fmt,$h)`, `to($fmt)`, denylist, `to_hash`),
   `responses` wire only. The other wires croak "not yet supported" so that nothing is
   half-wired.
2. `Tool->format_list` per-item partition. `ResponsesCompatible::chat_request` and
   `chat_stream_request` switch from the `$tools[0]` heuristic to
   `format_list('responses', …)` (pinned literal, like its `ToolChoice` pin, ADR 0010), plus
   the `server_tools` append.
3. `Role::ServerTools`, the `server_tools` flag, `%ROLE_TO_CAPS`, the manifest allowlist,
   and the `supports` croak in `chat_f`.
4. `ServerToolCall`, `Response.server_tool_calls`, and annotation citations. The Responses
   walker (dialect layer, ADR 0018 level 2) collects `url_citation` annotations. A
   `citations` key returned by `_responses_extra_fields` comes later in the constructor
   list and wins, so Perplexity is unchanged. The stream final chunk does the same.
5. The `summary` autovivification fix.
6. `Engine::XAIResponses`.
7. ADR (new) + 0003/0029 updates + `CONTEXT.md` terms (**ServerTool**, **Server tool call**).

### Phase 2 — Anthropic and Gemini

- **Anthropic:**
  - `to`/`from_hash` for `anthropic`;
  - the `server_tool_use` + `*_tool_result` blocks → `server_tool_calls`;
  - text-block `citations` → `Response.citations`;
  - `usage.server_tool_use` into `Langertha::Usage`;
  - **`pause_turn`**: `chat_with_tools_f` must re-send the turn instead of returning partial
    text. That is a loop behavior change and needs its own mini-design (and an ADR 0003/0005
    check). Also the beta headers **[verify]**.
- **Gemini:**
  - `gemini` branch of `format_list` (server tools as sibling `tools[]` entries next to the
    one `functionDeclarations` entry);
  - `groundingMetadata.groundingChunks` → citations;
  - `executableCode` / `codeExecutionResult` parts → `server_tool_calls` (and kept out of
    `content`);
  - the exclusion signature extension (§4).
- Perplexity explicit tools only if §2.5 verifies.

### Tests (skill `langertha-testing`)

- **Request building (`2x`, offline, no capture needed):**
  - `ServerTool->to` / wire-mismatch croak / denylist croak;
  - `format_list` partition with all five input kinds;
  - both mixed-list orders from §1, now correct;
  - engine `server_tools` appended on `chat_request` and `chat_stream_request`;
  - the `supports` croak on `Engine::OpenAI` (chat) given a `ServerTool`;
  - XAIResponses body `is_deeply` (model, `input`, `tools`, `reasoning`, `text.format`)
    against `/v1/responses` on `api.x.ai`.
- **Response parsing (`7x`/`9x`, verbatim captures in `t/data/`, `slurp_raw`, never
  hand-written):** `server_tool_calls`, citations (dedup, order), `tool_calls` empty for a
  server-only turn (the ADR 0003 invariant), no `summary` autovivification in `raw`.
- **Mocked async (`6x`, `Test::MockAsyncHTTP`):** a `chat_with_tools_f` turn whose response
  is the web-search capture makes **zero** `call_tool` calls and returns the text. A
  mixed capture (server call + `function_call`) executes exactly the function call, and
  the echo carries the server item.
- **Registry / manifest:** `t/78` sees `server_tools`; the Builder test classifies it and
  maps `XAIResponses` → `responses`.
- **Live:** none without the maintainer's OK. Candidate gated files: extend
  `85_live_responses` (OpenAI key) and a new xAI Responses live test
  (`TEST_LANGERTHA_XAI_API_KEY`).

**Captures that do not exist and need a maintainer-approved live call** (`t/data/` has only
`responses_api_text`, `responses_api_toolcall`, `responses_api_toolcall_toplevel` and
`perplexity_agent_search`, none with server-tool items or annotations):

| Capture | Provider | Needed for |
|---|---|---|
| `responses_web_search.json` (+ headers) — `web_search_call` + `message` with `url_citation` | OpenAI | Phase 1 parsing, loop test |
| `responses_web_search_function_call.json` — server call + `function_call` in one turn | OpenAI | loop executes only the function call |
| `xairesponses_chat_response.json` — plain text, encrypted reasoning item | xAI | walker, autoviv fix, `thinking` undef |
| `xairesponses_web_search.json` / `xairesponses_x_search.json` — server items + top-level `citations` | xAI | Phase 1 parsing, citations shape |
| `xairesponses_tool_call_response.json` — function call | xAI | function tools on the new engine |
| `xairesponses_stream.sse` — streamed web-search turn | xAI | stream event names, final-chunk citations |
| `anthropic_web_search.json`, `anthropic_pause_turn.json` | Anthropic | Phase 2 |
| `gemini_google_search.json`, `gemini_code_execution.json` | Gemini | Phase 2 |

Server-tool calls cost more than plain chat (per-search fees). The Phase 1 set is about six
calls on two keys. AKI.IO's standing exception does not apply here.

## 7. Non-goals

- A portable canonical vocabulary (`ServerTool->web_search` mapping to each provider's
  spelling) is not in Phase 1; see the open questions.
- No `previous_response_id` / server-side conversation state.
- No client-side executor for OpenAI/Anthropic client built-ins.
- No change to `chat_f`'s existing verbatim `tools` passthrough on non-supporting engines.

## 8. Open questions for the maintainer

1. **Portable names?** Should Phase 1 ship a small canonical constructor set
   (`ServerTool->web_search(%opts)` → `{type:'web_search'}` / `web_search_20250305` /
   `google_search`), or stay native-only until Anthropic and Gemini land? "Normalize,
   don't gatekeep" argues for it. The options differ per provider and the dated types
   drift, which argues against. The recommendation is native-only first.
2. **MCP approval flow:** OpenAI's remote-MCP `mcp_approval_request` needs a client
   round-trip. Should Phase 1 support remote MCP only with `require_approval:'never'` (croak
   otherwise), or design an approval hook now?
3. **Client-executed built-ins:** is the denylist croak acceptable, or should Langertha
   (later) route e.g. Anthropic `bash`/`text_editor` calls into the tool loop as ordinary
   client calls?
4. **Spend:** OK to make the Phase 1 capture calls (about six requests on OpenAI + xAI, with
   search fees)?
