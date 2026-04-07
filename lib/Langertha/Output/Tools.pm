package Langertha::Output::Tools;
our $VERSION = '0.310';
# ABSTRACT: Backwards-compat facade over Langertha::ToolCall
use strict;
use warnings;
use Langertha::ToolCall;

sub extract_from_raw {
  my ($class, $raw) = @_;
  my %meta = (
    text          => '',
    tool_calls    => [],
    finish_reason => undef,
  );
  return \%meta unless ref($raw) eq 'HASH';

  # Text + finish_reason extraction stays simple/manual: ToolCall is just
  # for tool invocations, the surrounding response shape is the caller's.
  my $msg = $raw->{message};
  if ( ref($msg) eq 'HASH' ) {
    $meta{text} = $msg->{content} // '';
    $meta{finish_reason} = $raw->{done_reason} if defined $raw->{done_reason};
  }
  elsif ( my $oai_msg = $raw->{choices}[0]{message} ) {
    $meta{text} = $oai_msg->{content} // '';
    $meta{finish_reason} = $raw->{choices}[0]{finish_reason}
      if defined $raw->{choices}[0]{finish_reason};
  }
  elsif ( ref( $raw->{content} ) eq 'ARRAY' ) {
    my @text;
    for my $block ( @{ $raw->{content} } ) {
      next unless ref($block) eq 'HASH';
      push @text, ( $block->{text} // '' ) if ( $block->{type} // '' ) eq 'text';
    }
    $meta{text} = join( '', @text );
    $meta{finish_reason} = $raw->{stop_reason} if defined $raw->{stop_reason};
  }

  $meta{tool_calls} = [ map { $_->to_hash } Langertha::ToolCall->extract($raw) ];
  return \%meta;
}

sub parse_hermes_calls_from_text {
  my ($class, $text) = @_;
  my ($clean, $calls) = Langertha::ToolCall->extract_hermes_from_text($text);
  return ( $clean, [ map { $_->to_hash } @$calls ] );
}

sub to_openai_tool_calls {
  my ($class, $canonical_calls) = @_;
  my @out;
  my $i = 0;
  for my $hash ( @{ $canonical_calls || [] } ) {
    $i++;
    next unless ref($hash) eq 'HASH';
    my $name = $hash->{name} // '';
    next unless length $name;
    my $tc = Langertha::ToolCall->new(
      name      => $name,
      arguments => ( ref( $hash->{arguments} ) eq 'HASH' ? $hash->{arguments} : {} ),
      id        => ( $hash->{id} // '' ),
    );
    push @out, $tc->to_openai( fallback_id => "call_langertha_$i" );
  }
  return \@out;
}

sub to_anthropic_tool_use_blocks {
  my ($class, $canonical_calls) = @_;
  my @out;
  my $i = 0;
  for my $hash ( @{ $canonical_calls || [] } ) {
    $i++;
    next unless ref($hash) eq 'HASH';
    my $name = $hash->{name} // '';
    next unless length $name;
    my $tc = Langertha::ToolCall->new(
      name      => $name,
      arguments => ( ref( $hash->{arguments} ) eq 'HASH' ? $hash->{arguments} : {} ),
      id        => ( $hash->{id} // '' ),
    );
    push @out, $tc->to_anthropic_block( fallback_id => "toolu_langertha_$i" );
  }
  return \@out;
}

sub to_ollama_tool_calls {
  my ($class, $canonical_calls) = @_;
  my @out;
  for my $hash ( @{ $canonical_calls || [] } ) {
    next unless ref($hash) eq 'HASH';
    my $name = $hash->{name} // '';
    next unless length $name;
    my $tc = Langertha::ToolCall->new(
      name      => $name,
      arguments => ( ref( $hash->{arguments} ) eq 'HASH' ? $hash->{arguments} : {} ),
      id        => ( $hash->{id} // '' ),
    );
    push @out, $tc->to_ollama;
  }
  return \@out;
}

1;
