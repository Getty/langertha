package Langertha::Role::Chat;
# ABSTRACT: Role for APIs with normal chat functionality

use Moose::Role;
use Future::AsyncAwait;
use Carp qw( croak );

requires qw(
  chat_request
  chat_response
);

has chat_model => (
  is => 'ro',
  isa => 'Str',
  lazy_build => 1,
);
sub _build_chat_model {
  my ( $self ) = @_;
  croak "".(ref $self)." can't handle models!" unless $self->does('Langertha::Role::Models');
  return $self->default_chat_model if $self->can('default_chat_model');
  return $self->model;
}

sub chat {
  my ( $self, @messages ) = @_;
  return $self->chat_request($self->chat_messages(@messages));
}

sub chat_messages {
  my ( $self, @messages ) = @_;
  return [$self->has_system_prompt
    ? ({
      role => 'system', content => $self->system_prompt,
    }) : (),
    map {
      ref $_ ? $_ : {
        role => 'user', content => $_,
      }
    } @messages];
}

sub simple_chat {
  my ( $self, @messages ) = @_;
  my $request = $self->chat(@messages);
  my $response = $self->user_agent->request($request);
  return $request->response_call->($response);
}

sub chat_stream {
  my ( $self, @messages ) = @_;
  croak "".(ref $self)." does not support streaming"
    unless $self->can('chat_stream_request');
  return $self->chat_stream_request($self->chat_messages(@messages));
}

sub simple_chat_stream {
  my ( $self, $callback, @messages ) = @_;
  croak "simple_chat_stream requires a callback as first argument"
    unless ref $callback eq 'CODE';
  my $request = $self->chat_stream(@messages);
  my $chunks = $self->execute_streaming_request($request, $callback);
  return join('', map { $_->content } @$chunks);
}

sub simple_chat_stream_iterator {
  my ( $self, @messages ) = @_;
  require Langertha::Stream;
  my $request = $self->chat_stream(@messages);
  my $chunks = $self->execute_streaming_request($request);
  return Langertha::Stream->new(chunks => $chunks);
}

# Future-based async methods

has _async_loop => (
  is => 'ro',
  lazy_build => 1,
);

sub _build__async_loop {
  require IO::Async::Loop;
  return IO::Async::Loop->new;
}

has _async_http => (
  is => 'ro',
  lazy_build => 1,
);

sub _build__async_http {
  my ($self) = @_;
  require Net::Async::HTTP;
  my $http = Net::Async::HTTP->new;
  $self->_async_loop->add($http);
  return $http;
}

async sub simple_chat_f {
  my ( $self, @messages ) = @_;
  my $request = $self->chat(@messages);

  my $response = await $self->_async_http->do_request(
    request => $request,
  );

  unless ($response->is_success) {
    die "".(ref $self)." request failed: ".$response->status_line;
  }

  return $request->response_call->($response);
}

sub simple_chat_stream_f {
  my ($self, @messages) = @_;
  return $self->simple_chat_stream_realtime_f(undef, @messages);
}

async sub simple_chat_stream_realtime_f {
  my ($self, $chunk_callback, @messages) = @_;

  croak "".(ref $self)." does not support streaming"
    unless $self->can('chat_stream_request');

  my $request = $self->chat_stream_request($self->chat_messages(@messages));
  my @all_chunks;
  my $buffer = '';
  my $format = $self->stream_format;
  my $response_status;

  await $self->_async_http->do_request(
    request => $request,
    on_header => sub {
      my ($response) = @_;
      $response_status = $response;

      # Return a callback that handles each body chunk
      return sub {
        my ($data) = @_;
        return unless defined $data;  # undef signals end of body

        $buffer .= $data;
        my $chunks = $self->_process_stream_buffer(\$buffer, $format);
        for my $chunk (@$chunks) {
          push @all_chunks, $chunk;
          $chunk_callback->($chunk) if $chunk_callback;
        }
      };
    },
  );

  unless ($response_status->is_success) {
    die "".(ref $self)." streaming request failed: ".$response_status->status_line;
  }

  # Process remaining buffer
  if ($buffer ne '') {
    my $chunks = $self->_process_stream_buffer(\$buffer, $format, 1);
    for my $chunk (@$chunks) {
      push @all_chunks, $chunk;
      $chunk_callback->($chunk) if $chunk_callback;
    }
  }

  my $content = join('', map { $_->content } @all_chunks);
  return ($content, \@all_chunks);
}

sub _process_stream_buffer {
  my ($self, $buffer_ref, $format, $final) = @_;

  my @chunks;

  if ($format eq 'sse') {
    while ($$buffer_ref =~ s/^(.*?)\n\n//s) {
      my $block = $1;
      for my $line (split /\n/, $block) {
        next if $line eq '' || $line =~ /^:/;
        if ($line =~ /^data:\s*(.*)$/) {
          my $json_data = $1;
          next if $json_data eq '[DONE]' || $json_data eq '';
          my $parsed = $self->json->decode($json_data);
          my $chunk = $self->parse_stream_chunk($parsed);
          push @chunks, $chunk if $chunk;
        }
      }
    }
  } elsif ($format eq 'ndjson') {
    while ($$buffer_ref =~ s/^(.*?)\n//s) {
      my $line = $1;
      next if $line eq '';
      my $parsed = $self->json->decode($line);
      my $chunk = $self->parse_stream_chunk($parsed);
      push @chunks, $chunk if $chunk;
    }
  }

  return \@chunks;
}

1;

=head1 SYNOPSIS

  # Synchronous chat
  my $response = $engine->simple_chat('Hello, how are you?');

  # Streaming with callback
  $engine->simple_chat_stream(sub {
    my ($chunk) = @_;
    print $chunk->content;
  }, 'Tell me a story');

  # Streaming with iterator
  my $stream = $engine->simple_chat_stream_iterator('Tell me a story');
  while (my $chunk = $stream->next) {
    print $chunk->content;
  }

  # Async with Future (traditional style)
  my $future = $engine->simple_chat_f('Hello');
  my $response = $future->get;

  # Async with Future::AsyncAwait (recommended)
  use Future::AsyncAwait;

  async sub chat_example {
    my ($engine) = @_;
    my $response = await $engine->simple_chat_f('Hello');
    say $response;
  }

  # Async streaming with Future::AsyncAwait
  async sub stream_example {
    my ($engine) = @_;
    my ($content, $chunks) = await $engine->simple_chat_stream_realtime_f(
      sub { print shift->content },
      'Tell me a story'
    );
    say "\nTotal chunks: ", scalar @$chunks;
  }

=head1 DESCRIPTION

This role provides chat functionality for LLM engines. It includes both
synchronous and asynchronous (Future-based) methods for chat and streaming.

=method simple_chat

  my $response = $engine->simple_chat(@messages);

Sends a chat request and returns the response content. Blocks until complete.

=method simple_chat_stream

  my $content = $engine->simple_chat_stream($callback, @messages);

Sends a streaming chat request. Calls C<$callback> with each chunk as it
arrives. Returns the complete content when done. Blocks until complete.

=method simple_chat_stream_iterator

  my $stream = $engine->simple_chat_stream_iterator(@messages);

Returns a L<Langertha::Stream> iterator object. Blocks while fetching,
then allows iteration over chunks.

=method simple_chat_f

  # Traditional Future style
  my $future = $engine->simple_chat_f(@messages);
  my $response = $future->get;

  # With async/await (recommended)
  use Future::AsyncAwait;
  async sub my_chat {
    my $response = await $engine->simple_chat_f(@messages);
    return $response;
  }

Async version of C<simple_chat>. Returns a L<Future> that resolves to
the response content. Implemented using L<Future::AsyncAwait> for clean
async/await syntax.

=method simple_chat_stream_f

  my $future = $engine->simple_chat_stream_f(@messages);
  my ($content, $chunks) = $future->get;

Async streaming without real-time callback. Returns a L<Future> that
resolves to the complete content and an arrayref of all chunks.

=method simple_chat_stream_realtime_f

  # Traditional Future style
  my $future = $engine->simple_chat_stream_realtime_f($callback, @messages);
  my ($content, $chunks) = $future->get;

  # With async/await (recommended)
  use Future::AsyncAwait;
  async sub my_stream {
    my ($content, $chunks) = await $engine->simple_chat_stream_realtime_f(
      sub { print shift->content },  # Real-time callback
      @messages
    );
    return $content;
  }

Async streaming with real-time callback. The C<$callback> is called with
each L<Langertha::Stream::Chunk> as it arrives from the server. Returns
a L<Future> that resolves to the complete content and all chunks.

This is the recommended method for real-time streaming in async applications.
Implemented using L<Future::AsyncAwait> for clean async/await syntax.

=head1 ASYNC IMPLEMENTATION

The Future-based methods are implemented using L<Future::AsyncAwait>, which
provides clean async/await syntax. Internally, they use L<IO::Async> and
L<Net::Async::HTTP> for non-blocking I/O. These modules are loaded lazily
only when you call one of the C<_f> methods, so synchronous usage doesn't
require them.

All C<_f> methods are defined with C<async sub>, allowing you to use
C<await> when calling them from your own async subroutines.

=head2 Integration with Mojolicious

For Mojolicious applications, use L<Future::Mojo> to bridge the event loops:

  use Future::Mojo;
  use Langertha::Engine::OpenAI;

  my $engine = Langertha::Engine::OpenAI->new(...);

  # Get the Future and use it with Mojo
  my $future = $engine->simple_chat_stream_realtime_f(
    sub { print shift->content },
    'Hello!'
  );

  $future->on_done(sub {
    my ($content, $chunks) = @_;
    # Handle completion
  });

  # Run the IO::Async loop (or integrate with Mojo::IOLoop)
  $engine->_async_loop->run;

=cut
