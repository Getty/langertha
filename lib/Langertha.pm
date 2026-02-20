package Langertha;
# ABSTRACT: The clan of fierce vikings with 🪓 and 🛡️ to AId your rAId
our $VERSION = '0.101';
use utf8;
use strict;
use warnings;

1;

=head1 SYNOPSIS

  my $system_prompt = <<__EOP__;

  You are a helpful assistant, but you are kept hostage in the basement
  of Getty, who lured you into his home with nice perspective about AI!

  __EOP__

Using L<https://ollama.com/>:

  use Langertha::Ollama;

  my $ollama = Langertha::Engine::Ollama->new(
    url => 'http://127.0.0.1:11434',
    model => 'llama3.1',
    system_prompt => $system_prompt,
  );

  print $ollama->simple_chat('Do you wanna build a snowman?');

Using L<https://platform.openai.com/>:

  use Langertha::OpenAI;

  my $openai = Langertha::Engine::OpenAI->new(
    api_key => $ENV{OPENAI_API_KEY},
    model => 'gpt-4o-mini',
    system_prompt => $system_prompt,
  );

  print $openai->simple_chat('Do you wanna build a snowman?');

Using L<https://console.anthropic.com/>:

  use Langertha::Anthropic;

  my $claude = Langertha::Engine::Anthropic->new(
    api_key => $ENV{ANTHROPIC_API_KEY},
    model => 'claude-sonnet-4-5-20250929',
  );

  print $claude->simple_chat('Generate Perl Moose classes to represent GeoJSON data.');

Using L<https://aistudio.google.com/>:

  use Langertha::Gemini;

  my $gemini = Langertha::Engine::Gemini->new(
    api_key => $ENV{GEMINI_API_KEY},
    model => 'gemini-2.0-flash',
  );

  print $gemini->simple_chat('Explain the difference between Moose and Moo.');

=head1 DESCRIPTION

Langertha provides a unified Perl interface for interacting with various Large Language Model (LLM) APIs.
It abstracts away provider-specific differences, giving you a consistent API whether you're using OpenAI,
Anthropic Claude, Ollama, Groq, Mistral, or other providers.

B<Key Features:>

=over 4

=item * Unified API across multiple LLM providers

=item * Streaming support (synchronous and asynchronous)

=item * Async/await syntax via L<Future::AsyncAwait>

=item * Role-based architecture for easy extensibility

=item * JSON response handling

=item * Temperature, response size, and other parameter controls

=back

B<Supported Engines:>

=over 4

=item * L<Langertha::Engine::Anthropic> - Claude models (Sonnet, Opus, Haiku)

=item * L<Langertha::Engine::OpenAI> - GPT-4, GPT-4o, GPT-3.5, o1, embeddings

=item * L<Langertha::Engine::Ollama> - Local LLM hosting

=item * L<Langertha::Engine::Groq> - Fast inference API

=item * L<Langertha::Engine::Mistral> - Mistral AI models

=item * L<Langertha::Engine::DeepSeek> - DeepSeek models

=item * L<Langertha::Engine::Gemini> - Google Gemini models (Flash, Pro)

=item * L<Langertha::Engine::vLLM> - vLLM inference server

=back

B<THIS API IS WORK IN PROGRESS>

=head1 STREAMING

All engines support streaming responses. There are several ways to use streaming:

=head2 Synchronous Streaming with Callback

  $engine->simple_chat_stream(sub {
    my ($chunk) = @_;
    print $chunk->content;
  }, 'Tell me a story');

=head2 Synchronous Streaming with Iterator

  my $stream = $engine->simple_chat_stream_iterator('Tell me a story');
  while (my $chunk = $stream->next) {
    print $chunk->content;
  }

=head2 Async Operations with Future

For non-blocking async operations, all engines provide Future-based methods.

B<Traditional Future style:>

  # Simple async chat (non-streaming)
  my $future = $engine->simple_chat_f('Hello');
  my $response = $future->get;

  # Async streaming - collect all chunks
  my $future = $engine->simple_chat_stream_f('Tell me a story');
  my ($content, $chunks) = $future->get;

  # Async streaming with real-time callback
  my $future = $engine->simple_chat_stream_realtime_f(
    sub {
      my ($chunk) = @_;
      print $chunk->content;
      STDOUT->flush;
    },
    'Tell me a story'
  );
  my ($content, $chunks) = $future->get;

B<Modern async/await style (recommended):>

  use Future::AsyncAwait;

  async sub chat_with_ai {
    my ($engine) = @_;

    # Clean, readable async code
    my $response = await $engine->simple_chat_f('Hello');
    say "AI says: $response";

    return $response;
  }

  async sub stream_chat {
    my ($engine) = @_;

    my ($content, $chunks) = await $engine->simple_chat_stream_realtime_f(
      sub { print shift->content },  # Real-time callback
      'Tell me a story'
    );

    say "\nReceived ", scalar(@$chunks), " chunks";
    return $content;
  }

  # Run async functions
  chat_with_ai($engine)->get;
  stream_chat($engine)->get;

The Future-based methods use L<IO::Async> and L<Net::Async::HTTP> internally,
which are loaded lazily only when you call the C<_f> methods.

See C<examples/async_await_example.pl> for complete working examples.

=head2 Using with Mojolicious

If you're using Mojolicious, you can integrate via L<Future::Mojo>:

  use Mojo::Base -strict;
  use Future::Mojo;
  use Langertha::Engine::OpenAI;

  my $openai = Langertha::Engine::OpenAI->new(
    api_key => $ENV{OPENAI_API_KEY},
    model => 'gpt-4o-mini',
  );

  # Wrap the IO::Async loop for Mojo compatibility
  my $loop = $openai->_async_loop;
  Future::Mojo->new($loop);

  # Now you can use the Future with Mojo's event loop
  my $future = $openai->simple_chat_stream_realtime_f(
    sub { print shift->content },
    'Hello!'
  );

  # Or convert to Mojo::Promise
  $future->on_done(sub {
    my ($content, $chunks) = @_;
    say "Done: $content";
  });

  Mojo::IOLoop->start;

=head1 SUPPORT

Repository

  https://github.com/Getty/langertha
  Pull request and additional contributors are welcome
 
Issue Tracker

  https://github.com/Getty/langertha/issues

Discord

  https://discord.gg/Y2avVYpquV 🤖

IRC

  irc://irc.perl.org/ai 🤖

=cut