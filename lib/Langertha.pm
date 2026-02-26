package Langertha;
# ABSTRACT: The clan of fierce vikings with 🪓 and 🛡️ to AId your rAId
our $VERSION = '0.301';
use utf8;
use strict;
use warnings;

use Import::Into;
use Module::Runtime qw( use_module );

my %_sugar_plugins;  # per-class plugin accumulator

my %setup = (
  Raider => sub {
    my ( $caller ) = @_;
    Moose->import::into($caller);
    Future::AsyncAwait->import::into($caller);
    $caller->meta->superclasses('Langertha::Raider');
    $_sugar_plugins{$caller} = [];
    no strict 'refs';
    *{"${caller}::plugin"} = sub {
      push @{$_sugar_plugins{$caller}}, @_;
    };
    $caller->meta->add_method('_sugar_plugins' => sub {
      return [@{$_sugar_plugins{$caller} // []}];
    });
  },
  Plugin => sub {
    my ( $caller ) = @_;
    Moose->import::into($caller);
    Future::AsyncAwait->import::into($caller);
    $caller->meta->superclasses('Langertha::Plugin');
  },
);

sub import {
  my ( $class, @args ) = @_;
  return unless @args;
  my $caller = caller;
  for my $arg (@args) {
    my $setup = $setup{$arg}
      or Carp::croak("Unknown Langertha import '$arg' (known: ".join(', ', sort keys %setup).")");
    require Moose;
    require Future::AsyncAwait;
    use_module('Langertha::Raider') if $arg eq 'Raider';
    use_module('Langertha::Plugin') if $arg eq 'Plugin';
    $setup->($caller);
  }
}

=head1 SYNOPSIS

    my $system_prompt = 'You are a helpful assistant.';

    # Local models via Ollama
    use Langertha::Engine::Ollama;

    my $ollama = Langertha::Engine::Ollama->new(
        url           => 'http://127.0.0.1:11434',
        model         => 'llama3.1',
        system_prompt => $system_prompt,
    );
    print $ollama->simple_chat('Do you wanna build a snowman?');

    # OpenAI
    use Langertha::Engine::OpenAI;

    my $openai = Langertha::Engine::OpenAI->new(
        api_key       => $ENV{OPENAI_API_KEY},
        model         => 'gpt-4o-mini',
        system_prompt => $system_prompt,
    );
    print $openai->simple_chat('Do you wanna build a snowman?');

    # Anthropic Claude
    use Langertha::Engine::Anthropic;

    my $claude = Langertha::Engine::Anthropic->new(
        api_key => $ENV{ANTHROPIC_API_KEY},
        model   => 'claude-sonnet-4-6',
    );
    print $claude->simple_chat('Generate Perl Moose classes to represent GeoJSON data.');

    # Google Gemini
    use Langertha::Engine::Gemini;

    my $gemini = Langertha::Engine::Gemini->new(
        api_key => $ENV{GEMINI_API_KEY},
        model   => 'gemini-2.5-flash',
    );
    print $gemini->simple_chat('Explain the difference between Moose and Moo.');

=head1 DESCRIPTION

Langertha provides a unified Perl interface for interacting with various Large
Language Model (LLM) APIs. It abstracts away provider-specific differences,
giving you a consistent API whether you're using OpenAI, Anthropic Claude,
Ollama, Groq, Mistral, or other providers.

B<THIS API IS WORK IN PROGRESS.>

=head2 Key Features

=over 4

=item * Unified API across multiple LLM providers

=item * Streaming support via callback, iterator, or L<Future>

=item * Async/await syntax via L<Future::AsyncAwait>

=item * Role-based architecture for easy extensibility

=item * JSON response handling

=item * Temperature, response size, and other parameter controls

=item * Plugin system for extending the Raider agent

=back

=head2 Class Sugar

Langertha can set up your package as a Raider subclass or Plugin role:

    # Build a custom Raider agent
    package MyAgent;
    use Langertha qw( Raider );
    plugin 'Langfuse';

    around plugin_before_llm_call => async sub {
        my ($orig, $self, $conversation, $iteration) = @_;
        $conversation = await $self->$orig($conversation, $iteration);
        # ... custom logic ...
        return $conversation;
    };

    __PACKAGE__->meta->make_immutable;

    # Build a custom Plugin
    package MyApp::Guardrails;
    use Langertha qw( Plugin );

    around plugin_before_tool_call => async sub {
        my ($orig, $self, $name, $input) = @_;
        my @result = await $self->$orig($name, $input);
        return unless @result;
        return if $name eq 'dangerous_tool';
        return @result;
    };

C<use Langertha qw( Raider )> imports L<Moose> and L<Future::AsyncAwait>,
sets L<Langertha::Raider> as superclass, and provides the C<plugin>
function for applying plugins by short name.

C<use Langertha qw( Plugin )> imports L<Moose> and
L<Future::AsyncAwait>, and sets L<Langertha::Plugin> as superclass.

=head2 Engine Modules

=over 4

=item * L<Langertha::Engine::Anthropic> - Claude models (Sonnet, Opus, Haiku)

=item * L<Langertha::Engine::OpenAI> - GPT-4, GPT-4o, GPT-3.5, o1, embeddings

=item * L<Langertha::Engine::Ollama> - Local LLM hosting via L<https://ollama.com/>

=item * L<Langertha::Engine::Groq> - Fast inference API

=item * L<Langertha::Engine::Mistral> - Mistral AI models

=item * L<Langertha::Engine::DeepSeek> - DeepSeek models

=item * L<Langertha::Engine::MiniMax> - MiniMax AI models (M2.5, M2.1)

=item * L<Langertha::Engine::Gemini> - Google Gemini models (Flash, Pro)

=item * L<Langertha::Engine::vLLM> - vLLM inference server

=item * L<Langertha::Engine::HuggingFace> - HuggingFace Inference Providers

=item * L<Langertha::Engine::Perplexity> - Perplexity AI models

=item * L<Langertha::Engine::NousResearch> - Nous Research models

=item * L<Langertha::Engine::OllamaOpenAI> - Ollama via OpenAI-compatible API

=item * L<Langertha::Engine::AKI> - AKI engine

=item * L<Langertha::Engine::AKIOpenAI> - AKI via OpenAI-compatible API

=item * L<Langertha::Engine::Whisper> - OpenAI Whisper speech-to-text

=back

=head2 Roles

Roles provide composable functionality to engines:

=over 4

=item * L<Langertha::Role::Chat> - Synchronous and async chat methods

=item * L<Langertha::Role::HTTP> - HTTP request/response handling

=item * L<Langertha::Role::Streaming> - Streaming response processing

=item * L<Langertha::Role::JSON> - JSON encode/decode

=item * L<Langertha::Role::OpenAICompatible> - OpenAI-compatible API behaviour

=item * L<Langertha::Role::SystemPrompt> - System prompt attribute

=item * L<Langertha::Role::Temperature> - Temperature parameter

=item * L<Langertha::Role::ResponseSize> - Max response size parameter

=item * L<Langertha::Role::ResponseFormat> - Response format (JSON mode)

=item * L<Langertha::Role::ContextSize> - Context window size parameter

=item * L<Langertha::Role::Seed> - Deterministic seed parameter

=item * L<Langertha::Role::Models> - Model listing

=item * L<Langertha::Role::Embedding> - Embedding generation

=item * L<Langertha::Role::Transcription> - Audio transcription

=item * L<Langertha::Role::Tools> - Tool/function calling

=item * L<Langertha::Role::ImageGeneration> - Image generation

=item * L<Langertha::Role::KeepAlive> - Keep-alive duration for local models

=item * L<Langertha::Role::PluginHost> - Plugin system for wrapper classes and Raider

=item * L<Langertha::Role::Langfuse> - Langfuse observability integration (engine-level)

=item * L<Langertha::Role::OpenAPI> - OpenAPI spec support

=back

=head2 Wrapper Classes

These classes wrap an engine with optional overrides and plugin lifecycle hooks:

=over 4

=item * L<Langertha::Chat> - Chat wrapper with system prompt, model, and temperature overrides

=item * L<Langertha::Embedder> - Embedding wrapper with optional model override

=item * L<Langertha::ImageGen> - Image generation wrapper with model, size, and quality overrides

=back

=head2 Plugins

=over 4

=item * L<Langertha::Plugin> - Base class for all plugins

=item * L<Langertha::Plugin::Langfuse> - Langfuse observability (traces, generations, spans)

=back

=head2 Data Objects

=over 4

=item * L<Langertha::Response> - LLM response with content and metadata

=item * L<Langertha::Stream> - Iterator over streaming chunks

=item * L<Langertha::Stream::Chunk> - A single chunk from a streaming response

=item * L<Langertha::Request::HTTP> - Internal HTTP request object

=item * L<Langertha::Raider> - Raider orchestration object

=back

=head2 Streaming

All engines that implement L<Langertha::Role::Chat> support streaming. There
are several ways to consume a stream:

B<Synchronous with callback:>

    $engine->simple_chat_stream(sub {
        my ($chunk) = @_;
        print $chunk->content;
    }, 'Tell me a story');

B<Synchronous with iterator (L<Langertha::Stream>):>

    my $stream = $engine->simple_chat_stream_iterator('Tell me a story');
    while (my $chunk = $stream->next) {
        print $chunk->content;
    }

B<Async with Future (traditional):>

    my $future = $engine->simple_chat_f('Hello');
    my $response = $future->get;

    my $future = $engine->simple_chat_stream_f('Tell me a story');
    my ($content, $chunks) = $future->get;

B<Async with Future::AsyncAwait (recommended):>

    use Future::AsyncAwait;

    async sub chat_with_ai {
        my ($engine) = @_;
        my $response = await $engine->simple_chat_f('Hello');
        say "AI says: $response";
        return $response;
    }

    async sub stream_chat {
        my ($engine) = @_;
        my ($content, $chunks) = await $engine->simple_chat_stream_realtime_f(
            sub { print shift->content },
            'Tell me a story',
        );
        say "\nReceived ", scalar(@$chunks), " chunks";
        return $content;
    }

    chat_with_ai($engine)->get;
    stream_chat($engine)->get;

The C<_f> methods use L<IO::Async> and L<Net::Async::HTTP> internally, loaded
lazily only when you call them. See C<examples/async_await_example.pl> for
complete working examples.

B<Using with Mojolicious:>

    use Mojo::Base -strict;
    use Future::Mojo;
    use Langertha::Engine::OpenAI;

    my $openai = Langertha::Engine::OpenAI->new(
        api_key => $ENV{OPENAI_API_KEY},
        model   => 'gpt-4o-mini',
    );

    my $future = $openai->simple_chat_stream_realtime_f(
        sub { print shift->content },
        'Hello!',
    );
    $future->on_done(sub {
        my ($content, $chunks) = @_;
        say "Done: $content";
    });
    Mojo::IOLoop->start;

=head2 Extensions

The C<LangerthaX> namespace is reserved for third-party extensions. See
L<LangerthaX>.

=cut

1;