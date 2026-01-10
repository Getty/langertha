package Langertha::Role::Async::Mojo;
# ABSTRACT: Async streaming with Mojo::UserAgent

use Moose::Role;
use Carp qw( croak );

requires qw(
  chat_stream_request
  chat_messages
  process_stream_data
  stream_format
);

has mojo_ua => (
  is => 'ro',
  lazy_build => 1,
);

sub _build_mojo_ua {
  require Mojo::UserAgent;
  return Mojo::UserAgent->new;
}

sub _request_to_mojo_tx {
  my ($self, $request) = @_;
  require Mojo::Transaction::HTTP;
  require Mojo::Message::Request;

  my $mojo_req = Mojo::Message::Request->new;
  $mojo_req->method($request->method);
  $mojo_req->url->parse($request->uri->as_string);

  # Copy headers
  $request->headers->scan(sub {
    my ($name, $value) = @_;
    $mojo_req->headers->header($name => $value);
  });

  # Copy body
  $mojo_req->body($request->content) if $request->content;

  return Mojo::Transaction::HTTP->new(req => $mojo_req);
}

sub simple_chat_stream_p {
  my ($self, @messages) = @_;
  return $self->simple_chat_stream_realtime_p(undef, @messages);
}

sub simple_chat_stream_realtime_p {
  my ($self, $chunk_callback, @messages) = @_;

  require Mojo::Promise;

  my $request = $self->chat_stream_request($self->chat_messages(@messages));
  my $tx = $self->_request_to_mojo_tx($request);
  my $buffer = '';
  my @all_chunks;
  my $format = $self->stream_format;

  # Set up real-time streaming via read event
  $tx->res->on(progress => sub {
    my ($res) = @_;
    return unless $res->content->is_chunked || length($res->body);

    my $new_data = $res->body;
    return if $new_data eq $buffer;

    my $new_part = substr($new_data, length($buffer));
    $buffer = $new_data;

    # Process new data for complete chunks
    my $chunks = $self->_process_partial_stream($new_part, $format);
    for my $chunk (@$chunks) {
      push @all_chunks, $chunk;
      $chunk_callback->($chunk) if $chunk_callback;
    }
  });

  return Mojo::Promise->new(sub {
    my ($resolve, $reject) = @_;

    $self->mojo_ua->start($tx => sub {
      my ($ua, $tx) = @_;

      if (my $err = $tx->error) {
        $reject->($err->{message});
        return;
      }

      # Process any remaining data
      my $final_data = $tx->res->body;
      if (length($final_data) > length($buffer)) {
        my $remaining = substr($final_data, length($buffer));
        my $chunks = $self->_process_partial_stream($remaining, $format);
        for my $chunk (@$chunks) {
          push @all_chunks, $chunk;
          $chunk_callback->($chunk) if $chunk_callback;
        }
      }

      my $content = join('', map { $_->content } @all_chunks);
      $resolve->($content, \@all_chunks);
    });
  });
}

sub _process_partial_stream {
  my ($self, $data, $format) = @_;

  my @chunks;

  if ($format eq 'sse') {
    # Process complete SSE blocks (ending with double newline)
    while ($data =~ s/^(.*?\n\n)//s) {
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
    # Process complete lines
    while ($data =~ s/^(.*?)\n//s) {
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
