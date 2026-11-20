# `chat_f` per wire — the rewrite matrix

Read this when a tools / `tool_choice` / `response_format` call behaves differently on one
provider, or before choosing an engine for structured output or forced tool calls.

Every path lands on `Response.tool_calls` as `Langertha::ToolCall`, so read it the same way on
every provider. What `chat_f` does per wire:

| You pass | Engine | Result |
|---|---|---|
| `tools` | `tools_native` | native tools on the wire |
| `tools` | only `tools_hermes` (NousResearch, AKI native) | tools rendered into the system prompt, `<tool_call>` blocks lifted onto `tool_calls`; `tool_choice => 'none'` withholds them |
| forced `tool_choice` | `tool_choice_named` | native forced tool |
| forced `tool_choice` | no `tool_choice_named`, has `response_format_json_schema` (Perplexity, NousResearch, some models) | rewritten to `json_schema`; `ToolCall` with `synthetic => 1` |
| `response_format` | first-party Anthropic | native `output_config.format` |
| `response_format` | `/anthropic` shim engines | synth tool + forced choice, lifted into `content` (no streaming) |
| `response_format` | Gemini / Ollama native | `responseJsonSchema` / `format` |
| `tools` + `response_format` | Groq, Cerebras | croaks |

## Engine quirks

- Perplexity (`/v1/agent`): client function tools, but no `tool_choice` /
  `parallel_tool_calls`, and no `json_object`.
- `OpenAIResponses` (`/v1/responses`): tools, no streaming.
- Groq also rejects `json_schema` with streaming.
- `chat_f` is one turn; MCP loops are `chat_with_tools_f` (→ `mcp-and-plugins.md`).
