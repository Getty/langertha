package Langertha::Role::Async::IOAsync;
# ABSTRACT: Async streaming with IO::Async

use Moose::Role;
use Carp qw( croak );

requires qw(
  chat_stream_request
  chat_messages
  process_stream_data
  stream_format
  json
  parse_stream_chunk
);

has ioasync_loop => (
  is => 'ro',
  lazy_build => 1,
);

sub _build_ioasync_loop {
  require IO::Async::Loop;
  return IO::Async::Loop->new;
}

has ioasync_http => (
  is => 'ro',
  lazy_build => 1,
);

sub _build_ioasync_http {
  my ($self) = @_;
  require Net::Async::HTTP;
  my $http = Net::Async::HTTP->new;
  $self->ioasync_loop->add($http);
  return $http;
}

sub simple_chat_stream_f {
  my ($self, @messages) = @_;
  return $self->simple_chat_stream_realtime_f(undef, @messages);
}

sub simple_chat_stream_realtime_f {
  my ($self, $chunk_callback, @messages) = @_;

  my $request = $self->chat_stream_request($self->chat_messages(@messages));
  my @all_chunks;
  my $buffer = '';
  my $format = $self->stream_format;

  my $on_chunk = sub {
    my ($data) = @_;
    $buffer .= $data;

    my $chunks = $self->_process_ioasync_buffer(\$buffer, $format);
    for my $chunk (@$chunks) {
      push @all_chunks, $chunk;
      $chunk_callback->($chunk) if $chunk_callback;
    }
  };

  return $self->ioasync_http->do_request(
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
      my $chunks = $self->_process_ioasync_buffer(\$buffer, $format, 1);
      for my $chunk (@$chunks) {
        push @all_chunks, $chunk;
        $chunk_callback->($chunk) if $chunk_callback;
      }
    }

    my $content = join('', map { $_->content } @all_chunks);
    return Future->done($content, \@all_chunks);
  });
}

sub _process_ioasync_buffer {
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
