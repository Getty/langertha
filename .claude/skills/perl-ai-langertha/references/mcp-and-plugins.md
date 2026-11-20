# Tool calling with MCP, and plugins

Read this when wiring MCP tools into a multi-turn tool loop (`chat_with_tools_f`), or when
writing / attaching a plugin.

## Tool calling with MCP

You bring the MCP client; Langertha does not depend on one. `mcp_servers` takes any
`Net::Async::MCP`-compatible client (it must answer `list_tools` and `call_tool`).

```perl
use MCP::Server; use Net::Async::MCP; use IO::Async::Loop;
my $server = MCP::Server->new(name => 'my-tools', version => '1.0');
$server->tool(
    name => 'search_files', description => 'Search files',
    input_schema => { type => 'object',
        properties => { pattern => { type => 'string' } }, required => ['pattern'] },
    code => sub { my ($tool, $args) = @_;          # $tool is MCP::Tool, not your class
        $tool->text_result(join "\n", glob $args->{pattern}) },   # (text, 1) = error
);
my $mcp = Net::Async::MCP->new(server => $server);
IO::Async::Loop->new->add($mcp);
await $mcp->initialize;
my $engine = Langertha::Engine::Anthropic->new( mcp_servers => [$mcp] );
my $response = await $engine->chat_with_tools_f('Find all .pm files in lib/');
```

`tool_max_iterations` caps the loop; Hermes engines run it with the tools in the prompt.

## Plugins

```perl
package Langertha::Plugin::MyGuard;  use Langertha qw( Plugin );
async sub plugin_before_tool_call {
    my ($self, $name, $input) = @_;
    return if $name eq 'dangerous_tool';   # empty list = skip the call
    return ($name, $input);
}
__PACKAGE__->meta->make_immutable;
```

Attach with `plugins => ['MyGuard', 'Langfuse']` (short names resolve to `Langertha::Plugin::*`,
then `LangerthaX::Plugin::*`). All hooks are `async sub`, chained in order.

| Host | Hooks that fire |
|---|---|
| `Langertha::Chat` (wraps an engine) | `plugin_before_llm_call($conv, $iter)`, `plugin_after_llm_response($data, $iter)`, `plugin_before_tool_call($name, $input)`, `plugin_after_tool_call($name, $input, $result)` |
| `Langertha::Embedder` / `Langertha::ImageGen` | `plugin_before/after_embedding`, `plugin_before/after_image_gen` |
| `Langertha::Raider` (langertha-raider) | the Chat hooks plus `plugin_before_raid(\@msgs)`, `plugin_build_conversation(\@conv)`, `plugin_after_raid($result)` |

Engines (`Engine::Remote`) also compose `Role::PluginHost` for `fire_event_f` custom events.
