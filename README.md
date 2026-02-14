# SYNOPSIS

    my $system_prompt = <<__EOP__;

    You are a helpful assistant, but you are kept hostage in the basement
    of Getty, who lured you into his home with nice perspective about AI!

    __EOP__

Using [https://ollama.com/](https://ollama.com/):

    use Langertha::Ollama;

    my $ollama = Langertha::Engine::Ollama->new(
        url => 'http://127.0.0.1:11434',
        model => 'llama3.1',
        system_prompt => $system_prompt,
    );

    print $ollama->simple_chat('Do you wanna build a snowman?');

Using [https://platform.openai.com/](https://platform.openai.com/):

    use Langertha::OpenAI;

    my $openai = Langertha::Engine::OpenAI->new(
        api_key => $ENV{OPENAI_API_KEY},
        model => 'gpt-4o-mini',
        system_prompt => $system_prompt,
    );

    print $openai->simple_chat('Do you wanna build a snowman?');

Using [https://console.anthropic.com/](https://console.anthropic.com/):

    use Langertha::Anthropic;

    my $claude = Langertha::Engine::Anthropic->new(
        api_key => $ENV{ANTHROPIC_API_KEY},
        model => 'claude-sonnet-4-5-20250929',
    );

    print $claude->simple_chat('Generate Perl Moose classes to represent GeoJSON data.');

Using [https://console.groq.com/](https://console.groq.com/):

    use Langertha::Engine::Groq;

    my $groq = Langertha::Engine::Groq->new(
        api_key => $ENV{GROQ_API_KEY},
        model => 'llama3-8b-8192',
        system_prompt => 'You are a helpful assistant',
    );

    print($groq->simple_chat('Say something nice'));

# ASYNC/AWAIT SUPPORT

Langertha supports async/await syntax via Future::AsyncAwait for non-blocking operations:

    use Future::AsyncAwait;
    use Langertha::Engine::Anthropic;

    async sub chat_example {
        my $claude = Langertha::Engine::Anthropic->new(
            api_key => $ENV{ANTHROPIC_API_KEY},
            model => 'claude-sonnet-4-5-20250929',
        );

        # Non-blocking chat request
        my $response = await $claude->simple_chat_f('Hello!');
        say "Claude says: $response";

        # Streaming with real-time callback
        my ($content, $chunks) = await $claude->simple_chat_stream_realtime_f(
            sub { print shift->content },  # Prints as it streams
            'Tell me a story'
        );
    }

    # Run the async function
    chat_example()->get;

See `examples/async_await_example.pl` for more examples.

# DYNAMIC MODEL DISCOVERY

Langertha can dynamically fetch available models from provider APIs:

    # Get list of available models
    my $models = $engine->list_models;
    # Returns: ['gpt-4o', 'gpt-4o-mini', 'o1', ...]

    # Get full model metadata
    my $models = $engine->list_models(full => 1);
    # Returns: [{id => 'gpt-4o', created => 1715367049, ...}, ...]

    # Force refresh (bypass 1-hour cache)
    my $models = $engine->list_models(force_refresh => 1);

    # Configure cache TTL
    my $engine = Langertha::Engine::OpenAI->new(
        api_key => $ENV{OPENAI_API_KEY},
        models_cache_ttl => 1800, # 30 minutes
    );

    # Clear cache manually
    $engine->clear_models_cache;

Supported by all engines: OpenAI, Anthropic, Gemini, Groq, DeepSeek, Mistral, and Ollama.

# ANTHROPIC EXTENDED PARAMETERS (FEBRUARY 2026)

Anthropic's latest models support extended parameters:

    my $claude = Langertha::Engine::Anthropic->new(
        api_key => $ENV{ANTHROPIC_API_KEY},
        model => 'claude-opus-4-6-20250514',
        effort => 'high',          # Thinking depth: low|medium|high
        inference_geo => 'eu',     # Data residency: us|eu
    );

- **effort**: Controls reasoning depth for complex tasks
- **inference_geo**: Ensures data processing in specific regions

# DESCRIPTION

**THIS API IS WORK IN PROGRESS**

# SUPPORT

Repository

    https://github.com/Getty/langertha
    Pull request and additional contributors are welcome

Issue Tracker

    https://github.com/Getty/langertha/issues

Discord

    https://discord.gg/Y2avVYpquV

IRC

    irc://irc.perl.org/ai
