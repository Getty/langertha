package Langertha::Role::Chat;
# ABSTRACT: Role for APIs with normal chat functionality

use Moose::Role;
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

sub simple_chat_f {
  my ( $self, @messages ) = @_;
  require Future;
  my $request = $self->chat(@messages);

  return $self->_async_http->do_request(
    method => $request->method,
    uri => $request->uri,
    headers => { $request->headers->flatten },
    content => $request->content,
  )->then(sub {
    my ($response) = @_;
    unless ($response->is_success) {
      die "".(ref $self)." request failed: ".$response->status_line;
    }
    return Future->done($request->response_call->($response));
  });
}

sub simple_chat_stream_f {
  my ($self, @messages) = @_;
  return $self->simple_chat_stream_realtime_f(undef, @messages);
}

sub simple_chat_stream_realtime_f {
  my ($self, $chunk_callback, @messages) = @_;
  require Future;

  croak "".(ref $self)." does not support streaming"
    unless $self->can('chat_stream_request');

  my $request = $self->chat_stream_request($self->chat_messages(@messages));
  my @all_chunks;
  my $buffer = '';
  my $format = $self->stream_format;

  my $on_chunk = sub {
    my ($data) = @_;
    $buffer .= $data;

    my $chunks = $self->_process_stream_buffer(\$buffer, $format);
    for my $chunk (@$chunks) {
      push @all_chunks, $chunk;
      $chunk_callback->($chunk) if $chunk_callback;
    }
  };

  return $self->_async_http->do_request(
    method => $request->method,
    uri => $request->uri,
    headers => { $request->headers->flatten },
    content => $request->content,
    on_body_chunk => $on_chunk,
  )->then(sub {
    my ($response) = @_;

    unless ($response->is_success) {
      die "".(ref $self)." streaming request failed: ".$response->status_line;
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
    return Future->done($content, \@all_chunks);
  });
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
