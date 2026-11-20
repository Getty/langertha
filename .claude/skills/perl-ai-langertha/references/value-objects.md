# Response fields and value objects

Read this when reading usage, rate limits, timing or timestamps off a Response, or when
building / parsing tool payloads, images or non-chat results by hand.

## Reading a Response

`content`, `model`, `finish_reason`, `thinking`, `citations`, `tool_calls`;
`usage` (a `Langertha::Usage`: `input_tokens`, `output_tokens`, `total_tokens`,
`cached_tokens`, `cache_write_tokens`; `->{...}` still gives the provider hash);
`rate_limit` (`Langertha::RateLimit`: `requests_remaining`, `tokens_remaining`, and per bucket
`*_reset_at` — a `Moment` — plus `*_reset_after` seconds; `undef` when the wire sent nothing);
`created` (`Langertha::Moment`: numifies to the epoch, stringifies to ISO-8601);
`ttft_seconds` / `total_seconds` (`timing` holds engine-native stages). Test with the
`has_*` predicates before reading optional fields.

## Value objects

| Class | Use |
|---|---|
| `Langertha::Tool` | `from_hash` (MCP / Anthropic / OpenAI / Gemini shapes), `from_list`; `->to($fmt)`; `Tool->format_list($fmt, \@tools)` builds a whole `tools` payload |
| `Langertha::ToolCall` | `ToolCall->extract($fmt, $data)` → list of calls from a raw response (croaks if `$fmt` is a ref); `extract_sniff($data)` only when the format is unknown |
| `Langertha::ToolChoice` | `auto` / `any` / `none` / `specific($name)`, `from_hash`; `->to($fmt)` |
| `Langertha::ToolResult` | `name`, `id`, `content` (MCP content array), `is_error`; `->to($fmt)` gives the result block |
| `Langertha::Usage`, `RateLimit`, `Moment` | see above; `Moment->from_wire($v)` returns undef instead of dying |
| `Langertha::Content::Image` | `from_url` / `from_file` / `from_data` / `from_base64`; put it in `content => [ $text, $img ]` |
| `Langertha::CallResult` | from `simple_embedding_result(_f)` / `simple_transcription_call(_f)` / `simple_image_result(_f)`: `value` plus `usage`, `rate_limit`, `model`, `total_seconds`, `raw` (the bare `simple_embedding` / `simple_transcription` / `simple_image` and their `_f` return only the value) |
| `Langertha::RunContext`, `Role::Runnable` | generic run context + `run_f` contract, used by Raider/Raid nodes |

`$fmt` is a `tool_wire_format`: `openai`, `anthropic`, `gemini`, `ollama`, `responses`
(plus `hermes` / `mcp` for `Tool`). Use the engine's own `$engine->tool_wire_format`.
