# ADR 0001 — Tool wire-translation routes through value objects keyed by `tool_wire_format`

- Status: accepted
- Date: 2026-06-26
- Tags: tools, wire-format, value-objects, engines

## Context

Langertha talks to ~25 engines across several incompatible tool dialects: OpenAI
`chat/completions`, Anthropic `/v1/messages`, Gemini `functionDeclarations`, the OpenAI
Responses API, Ollama's native shape, and the Hermes XML convention for models with no native
tool support. Every dialect differs on three axes: how outbound tool *definitions* are
serialized, how inbound tool *calls* are located and parsed out of a response, and how tool
*results* are wrapped into the next-turn message envelope.

Historically each engine carried its own copies of `format_tools`, `response_tool_calls`,
`extract_tool_call`, `format_tool_results` and `response_text_content`. That meant the same
five per-format behaviours were duplicated and drifted across two dozen engine classes; a fix
to the Anthropic tool-result shape had to be applied in every Anthropic-family engine, and a
new provider meant pasting five more methods.

## Decision

1. **An engine declares exactly one `tool_wire_format`** — the enum `openai` | `anthropic` |
   `gemini` | `ollama` | `responses` | `hermes` (`Langertha::Role::Tools`). Its default follows
   the engine base-class hierarchy (`OpenAIBase` leaves it `openai`, `AnthropicBase` overrides
   to `anthropic`, …), so concrete engines inherit it and carry **no tool-format code of their
   own**. Override `_build_tool_wire_format` to change it.

2. **All wire-translation lives in canonical value objects, dispatched by that one tag:**
   - outbound definitions — `Langertha::Tool->to($fmt)` / `->format_list($fmt, \@mcp_tools)`
   - inbound calls — `Langertha::ToolCall` (`->locate($fmt, $data)` finds the raw structures,
     `->from_fmt($fmt, $hash)` parses one; `->extract($fmt, $data)` is the combined form)
   - result blocks — `Langertha::ToolResult->to($fmt)`

   `Langertha::Role::Tools` holds only the **thin tag-driven orchestration** that calls these
   (`format_tools`, `response_tool_calls`, `extract_tool_call`, `format_tool_results`,
   `response_text_content`). Engines carry none of it.

3. **`hermes` is a `tool_wire_format` value like any other.** Its outbound is system-prompt
   injection and its inbound is `<tool_call>` XML parsing, selected by the same tag; the tag
   names and prompt template come from `Langertha::Role::HermesTools`. It is not a separate
   code path bolted onto the loop — it is one branch of the same dispatch.

## Rationale

A new provider becomes a new tag value plus branches inside the value objects — never new
methods on an engine. A wire-shape fix happens once, in the value object, and every engine of
that format gets it. The engine classes shrink to configuration (which roles, which default
tag), which is the level they should operate at. `CONTEXT.md` fixes the vocabulary for this
seam (`tool_wire_format`, **Tool**, **ToolCall**, **ToolResult**, **Result envelope**,
**Assistant echo**) so the terms stay stable across future refactors.

## Consequences

- Adding a **format** = extend the value objects + the `Role::Tools` branches. Adding an
  **engine** of an existing format = zero tool code, just compose the roles and inherit the tag.
- **Result-envelope arity stays in `Role::Tools::format_tool_results`, not in `ToolResult`.**
  A `ToolResult` serializes exactly one block; the envelope (the **Assistant echo** of the
  prior turn plus N result blocks, where N-per-message differs — OpenAI emits N `role:tool`
  messages, Anthropic/Gemini one message with N blocks) is assembled by the orchestration. This
  split is deliberate: the block formatter knows nothing about the surrounding conversation.
- `Role::HermesTools` keeps the tags/template but is no longer a parallel tool-calling
  subsystem — it is the data behind one tag value. It is not retired: it also carries the
  overridable `hermes_extract_content` (for engines whose response shape is not OpenAI's) and
  is the `does()` source of the `tools_hermes` capability flag (ADR 0002).
- **`TO_JSON` is the canonical shape, not a wire shape.** `Role::JSON`'s shared encoder gained
  `convert_blessed` (karr k120, commit `b9ec772`) so the distribution's value objects serialize
  through their `TO_JSON` instead of croaking — that is for traces, logs and `UsageRecord`-style
  data, and it is **not** a second outbound door. Note the sharp edge it introduces: handing a
  `Langertha::Tool` straight into a request body now yields `to_hash`
  (`name` / `description` / `input_schema`), which is byte-identical to `to_anthropic` — so on
  any wire that is not Anthropic's it is the wrong dialect, emitted silently, where it used to
  be a loud croak. The tag remains the only outbound door: `Tool->to($fmt)` /
  `->format_list($fmt, \@mcp_tools)`.
- **A per-format serializer may also key on the schema *shape*, not only on the tag.** k133 gave
  `Tool->to_anthropic` a top-level `strict: true` — but only for a **closed** `input_schema`
  (`additionalProperties:false` + a non-empty `required`); it stays silent otherwise, because
  Anthropic 400s on `strict` over an open schema. The decision is keyed on the schema, not on
  any engine or `tool_wire_format` value, so it lives inside the value object exactly like the
  rest of `to_anthropic` — the "value object owns its wire shape" principle of this ADR,
  extended to a per-schema wire toggle. See the ADR 0005 Update (k133).

## Future work

- **Reconcile the two inbound entry points.** ~~`ToolCall->extract($fmt, $data)` is the unified
  locate+parse API, but the loop (`Role::Tools::response_tool_calls` + `extract_tool_call`)
  uses the lower-level `locate` + `from_fmt` split, and the legacy self-sniffing
  `extract($data)` form duplicates the per-format response-walking already in `locate`. Collapse
  to one canonical inbound path so there is a single place the per-format walking lives.~~
  **Resolved — see ADR 0010.** `extract($fmt, $data)` is now the single canonical inbound entry
  (per-format walking lives only in `locate`); self-sniffing is the explicitly-named
  `extract_sniff`; and `ToolChoice` gained the symmetric `to($fmt)` the other three value
  objects already had. The loop's `locate` / `from_fmt` split is kept deliberately (it threads
  raw structures to the result-envelope rebuild) — ADR 0010 records why.

## Update (k210 — only function tools pass the `Tool` door; `classify` names the rest; the Responses envelope decides per item)

The inbound door `Tool->from_hash` had no notion of a tool that is not a function tool. It
routed any hash by shape. So `{type=>'web_search'}`, Gemini's keyed `{google_search=>{}}` and
`{functionDeclarations=>[…]}` (no `name`) returned `undef`, and `from_list` / `format_list`
dropped them. Anthropic's `{type=>'web_search_20250305', name=>'web_search'}` fell through to
`from_anthropic` and became a *function* tool with an empty schema. Either way the request lost
its meaning without a word.

**One classifier.** `Tool->classify($hash, $fmt)` is public and never croaks. It returns
`function`, `server`, `client_builtin`, `foreign` (a built-in of a wire other than `$fmt`) or
`unknown`. In list context it also returns the wire and a label. It is the single source of
truth: the door croaks from it, `ResponsesCompatible` decides from it, and a sibling gateway can
map it to a 400 instead of dying (k216). A function tool is recognized by its `type`, not by
guessing from the rest of the shape: no `type` plus a `name` (canonical, MCP, Gemini, Anthropic
client tool), `type => 'function'` (OpenAI), or `custom` *with* an `input_schema` (Anthropic's
explicit client tool).

Built-ins are recognized explicitly per wire, from the provider documentation (spec k206 §3.4;
llm-advisor against the OpenAI create-response reference). "Any other `type` is server-side"
would be wrong.

- responses, server: `web_search` (also dated `web_search_YYYY_MM_DD`), `web_search_preview*`,
  `file_search`, `code_interpreter`, `image_generation`, `mcp`, `x_search`,
  `collections_search`, `tool_search` unless `execution: "client"`, and `shell` with a
  `container_*` environment.
- responses, client-executed: `local_shell`, `computer`, `computer_use_preview`, `apply_patch`,
  `shell` with a local environment, and `tool_search` with `execution: "client"`.
- anthropic: server `web_search_*`, `web_fetch_*`, `code_execution_*`, `tool_search_tool_*`
  (versioned) and `mcp_toolset`. Client-executed `bash_*`, `text_editor_*`, `computer_*` and
  `memory_*`.
- gemini (keyed, snake and camel case, ADR 0018): server `google_search`,
  `google_search_retrieval`, `code_execution`, `url_context`, `google_maps`,
  `enterprise_web_search`, `file_search` and `retrieval`. Client-executed `computer_use`.

**The door fails closed.** `from_hash` / `from_list` / `format_list` croak on every category
except `function`. The messages differ per category: a server-side tool "not supported yet", a
client-executed built-in "not a server tool", an unsupported `type`, or a hash with no `type`
and no `name`. Nothing is dropped silently any more. The one exception is the flat Responses
function form, which `from_openai` still cannot parse; that predates this change and is k217.
Every function-tool form the door accepted before is pinned in `t/92_tool_input_forms.t`. The
server-side croak is interim until server-side tools get their own value object (k206). It is
a croak and not a pass-through because `from_hash`'s callers only ever emit function tools.

**The Responses envelope decides per item, by denylist.** `ResponsesCompatible::chat_request`
used to format the whole `tools` list only when the *first* item had no `type`. A typed item
first sent an MCP tool out unformatted (400). An MCP tool first dropped a built-in and turned
`custom` / `namespace` into function tools. Now each item is decided on its own and the order is
kept, as spec §3.4 says (`_is_native_responses_tool`). A flat `{type=>'function', …}`, a
Responses `server` tool, and any typed `unknown` go out verbatim, so the provider judges them
(values open). That covers `custom`, `namespace`, a `shell` without an environment and future
server types. Other function-tool forms (MCP, canonical, OpenAI chat's nested `function`, a
`Langertha::Tool`, an Anthropic `custom`) are formatted. A Responses `client_builtin`, a
`foreign` built-in, and an untyped nameless hash croak at the door. Known client-executed
built-ins croak even though they went out verbatim when listed first before this change, per
the Q3 ruling on k206: their `*_call` output items are not mapped, so the turn would end
silently. Loop integration for them is future work.

Not yet consistent, and deliberately so: `custom` goes out verbatim, but its `custom_tool_call`
output is not mapped into `Response.tool_calls` either (`ToolCall` only knows `function_call`).
So a turn that calls it ends with empty `tool_calls`. The spec keeps `custom` verbatim on
purpose. The inbound fail-loud for unmapped client-actionable items belongs to k206
(llm-advisor must-change 1).
