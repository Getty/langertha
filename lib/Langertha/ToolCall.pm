package Langertha::ToolCall;
# ABSTRACT: Immutable canonical tool invocation emitted by an LLM
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );
use Encode qw( encode_utf8 );
use JSON::MaybeXS qw( encode_json decode_json );

has name => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

has arguments => (
  is      => 'ro',
  isa     => 'HashRef',
  default => sub { {} },
);

# Provider-specific call id (may be empty if the upstream didn't supply one).
has id => (
  is      => 'ro',
  isa     => 'Str',
  default => '',
);

# True when this call was synthesized by Langertha (e.g. forced-tool
# rewrite via response_format on engines without native named-tool
# forcing) rather than emitted directly by the model. Useful for
# callers that want to distinguish "the model decided to call this"
# from "we asked it to and parsed the result back into a tool_call".
has synthetic => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

=attr synthetic

Boolean. True when the tool call was synthesized by Langertha — for
example when L<Langertha::Role::Chat/chat_f> rewrote a forced named
tool into a C<response_format> JSON Schema request and parsed the
output back into a C<ToolCall>. False (the default) for native model
output.

=cut

sub _decode_args {
  my ($args) = @_;
  return {} unless defined $args;
  return $args if ref($args) eq 'HASH';
  return {} unless length $args;
  # Argument strings reach us as Perl-Unicode (pulled out of an already-decoded
  # response tree), so UTF-8-encode before the utf8 JSON decoder — same
  # convention as Role::JSON's decode_json_text.
  my $decoded = eval { decode_json( encode_utf8($args) ) };
  return ( ref($decoded) eq 'HASH' ) ? $decoded : {};
}

# --- Constructors from wire-format hashes ---

sub from_openai {
  my ($class, $hash) = @_;
  return undef unless ref($hash) eq 'HASH';
  my $fn = $hash->{function} || {};
  return undef unless ref($fn) eq 'HASH';
  my $name = $fn->{name} // '';
  return undef unless length $name;
  return $class->new(
    name      => $name,
    arguments => _decode_args( $fn->{arguments} ),
    id        => ( $hash->{id} // '' ),
  );
}

sub from_anthropic {
  my ($class, $block) = @_;
  return undef unless ref($block) eq 'HASH';
  return undef unless ( $block->{type} // '' ) eq 'tool_use';
  my $name = $block->{name} // '';
  return undef unless length $name;
  return $class->new(
    name      => $name,
    arguments => ( ref( $block->{input} ) eq 'HASH' ? $block->{input} : {} ),
    id        => ( $block->{id} // '' ),
  );
}

sub from_ollama {
  my ($class, $hash) = @_;
  return undef unless ref($hash) eq 'HASH';
  my $fn = $hash->{function} || {};
  return undef unless ref($fn) eq 'HASH';
  my $name = $fn->{name} // '';
  return undef unless length $name;
  return $class->new(
    name      => $name,
    arguments => _decode_args( $fn->{arguments} ),
    id        => ( $hash->{id} // '' ),
  );
}

# Gemini: a single functionCall part inside candidates[0].content.parts[]:
#   { "functionCall": { "name": "x", "args": { ... } } }
sub from_gemini {
  my ($class, $part) = @_;
  return undef unless ref($part) eq 'HASH';
  my $fc = $part->{functionCall};
  return undef unless ref($fc) eq 'HASH';
  my $name = $fc->{name} // '';
  return undef unless length $name;
  return $class->new(
    name      => $name,
    arguments => ( ref( $fc->{args} ) eq 'HASH' ? $fc->{args} : {} ),
    id        => ( $fc->{id} // '' ),
  );
}

# OpenAI Responses API: function_call appears either as a top-level output[]
# item or nested inside output[type=message].content[]. Both shapes look like:
#   { "type": "function_call", "call_id": "call_abc", "name": "foo", "arguments": "{...}" }
sub from_responses {
  my ($class, $block) = @_;
  return undef unless ref($block) eq 'HASH';
  # The sniffing extract() pre-filters output[] items by type, and a located
  # call passed to from_fmt may carry no type at all — only reject a block
  # whose type is present AND wrong.
  my $type = $block->{type};
  return undef if defined $type && $type ne 'function_call';
  my $name = $block->{name} // '';
  return undef unless length $name;
  my $args = $block->{arguments};
  $args = _decode_args($args);
  return $class->new(
    name      => $name,
    arguments => ( ref($args) eq 'HASH' ? $args : {} ),
    id        => ( $block->{call_id} // '' ),
  );
}

# Maps a tool_wire_format tag to the per-call constructor.
my %FROM_METHOD = (
  openai    => 'from_openai',
  anthropic => 'from_anthropic',
  gemini    => 'from_gemini',
  ollama    => 'from_ollama',
  responses => 'from_responses',
);

# Construct a single ToolCall from one raw wire-format call hash, pinned to a
# format (no shape sniffing). Returns undef if the hash doesn't parse.
sub from_fmt {
  my ($class, $fmt, $hash) = @_;
  my $method = $FROM_METHOD{ $fmt // '' }
    or croak "Langertha::ToolCall: unknown wire format '" . ( $fmt // '' ) . "'";
  return $class->$method($hash);
}

# Locate the raw tool-call structures inside an upstream response for a given
# format, WITHOUT parsing them into objects. Returns an arrayref of raw hashes
# (possibly empty). This is the per-format locator that engines used to carry
# as response_tool_calls.
sub locate {
  my ($class, $fmt, $data) = @_;
  $fmt //= '';
  return [] unless ref($data) eq 'HASH';

  if ( $fmt eq 'openai' ) {
    my $msg = $data->{choices}[0]{message} or return [];
    return $msg->{tool_calls} // [];
  }
  if ( $fmt eq 'ollama' ) {
    my $msg = $data->{message} or return [];
    return $msg->{tool_calls} // [];
  }
  if ( $fmt eq 'anthropic' ) {
    return [ grep { ( $_->{type} // '' ) eq 'tool_use' } @{ $data->{content} // [] } ];
  }
  if ( $fmt eq 'gemini' ) {
    my $candidates = $data->{candidates} || [];
    return [] unless @$candidates;
    my $parts = $candidates->[0]{content}{parts} || [];
    return [ grep { exists $_->{functionCall} } @$parts ];
  }
  if ( $fmt eq 'responses' ) {
    my @calls;
    for my $item ( @{ $data->{output} // [] } ) {
      next unless ref($item) eq 'HASH';
      my $type = $item->{type} // '';
      if ( $type eq 'function_call' ) {
        push @calls, $item;
      }
      elsif ( $type eq 'message' ) {
        push @calls,
          grep { ( $_->{type} // '' ) eq 'function_call' } @{ $item->{content} // [] };
      }
    }
    return \@calls;
  }
  croak "Langertha::ToolCall: unknown wire format '$fmt'";
}

# Pull every tool call out of an upstream response. Two forms:
#   extract($fmt, $data) — pinned to a format (locate + from_fmt), no sniffing
#   extract($data)       — legacy self-dispatching sniff across all formats
# Both return a list of ToolCall objects (possibly empty).
sub extract {
  my ( $class, @args ) = @_;
  if ( @args == 2 ) {
    my ( $fmt, $data ) = @args;
    return grep { defined }
      map { $class->from_fmt( $fmt, $_ ) } @{ $class->locate( $fmt, $data ) };
  }
  my ($raw) = @args;
  return () unless ref($raw) eq 'HASH';

  # OpenAI shape: choices[0].message.tool_calls
  if ( my $oai_msg = $raw->{choices}[0]{message} ) {
    if ( ref( $oai_msg->{tool_calls} ) eq 'ARRAY' ) {
      return grep { defined } map { $class->from_openai($_) } @{ $oai_msg->{tool_calls} };
    }
  }

  # Ollama shape: message.tool_calls
  if ( my $msg = $raw->{message} ) {
    if ( ref( $msg->{tool_calls} ) eq 'ARRAY' ) {
      return grep { defined } map { $class->from_ollama($_) } @{ $msg->{tool_calls} };
    }
  }

  # Anthropic shape: content[*] where type=tool_use
  if ( ref( $raw->{content} ) eq 'ARRAY' ) {
    return grep { defined } map { $class->from_anthropic($_) } @{ $raw->{content} };
  }

  # Gemini shape: candidates[0].content.parts[*].functionCall
  if ( ref( $raw->{candidates} ) eq 'ARRAY'
    && ref( $raw->{candidates}[0]{content}{parts} ) eq 'ARRAY' ) {
    return grep { defined }
      map { $class->from_gemini($_) }
      @{ $raw->{candidates}[0]{content}{parts} };
  }

  # OpenAI Responses shape: function_call appears either as a top-level
  # output[] item (real API) or nested under output[type=message].content[]
  # (older / streaming shape). Walk both.
  if ( ref( $raw->{output} ) eq 'ARRAY' ) {
    my @calls;
    for my $item (@{$raw->{output}}) {
      next unless ref($item) eq 'HASH';
      my $type = $item->{type} // '';
      if ( $type eq 'function_call' ) {
        if ( my $tc = $class->from_responses($item) ) {
          push @calls, $tc;
        }
      }
      elsif ( $type eq 'message' ) {
        for my $block (@{$item->{content} // []}) {
          if (($block->{type} // '') eq 'function_call') {
            if (my $tc = $class->from_responses($block)) {
              push @calls, $tc;
            }
          }
        }
      }
    }
    return @calls if @calls;
  }

  return ();
}

# Hermes-style XML embedded in plain text. Returns ($cleaned_text, \@calls).
sub extract_hermes_from_text {
  my ($class, $text) = @_;
  my $clean = defined($text) ? $text : '';
  my @calls;
  while ( $clean =~ m{<tool_call>\s*(.*?)\s*</tool_call>}sg ) {
    my $json = $1;
    my $obj = eval { decode_json($json) };
    next unless ref($obj) eq 'HASH';
    next unless defined $obj->{name} && length $obj->{name};
    push @calls, $class->new(
      name      => $obj->{name},
      arguments => ( ref( $obj->{arguments} ) eq 'HASH' ? $obj->{arguments} : {} ),
    );
  }
  $clean =~ s{<tool_call>.*?</tool_call>}{}sg;
  $clean =~ s/^\s+|\s+$//g;
  return ( $clean, \@calls );
}

# --- Serializers to wire-format hashes ---

sub to_openai {
  my ($self, %opts) = @_;
  my $id = length( $self->id ) ? $self->id : ( $opts{fallback_id} // 'call_langertha' );
  return {
    id       => $id,
    type     => 'function',
    function => {
      name      => $self->name,
      arguments => encode_json( $self->arguments ),
    },
  };
}

sub to_anthropic_block {
  my ($self, %opts) = @_;
  my $id = length( $self->id ) ? $self->id : ( $opts{fallback_id} // 'toolu_langertha' );
  return {
    type  => 'tool_use',
    id    => $id,
    name  => $self->name,
    input => $self->arguments,
  };
}

sub to_ollama {
  my ($self) = @_;
  return {
    function => {
      name      => $self->name,
      arguments => $self->arguments,
    },
    ( length( $self->id ) ? ( id => $self->id ) : () ),
  };
}

sub to_hash {
  my ($self) = @_;
  return {
    id        => $self->id,
    name      => $self->name,
    arguments => $self->arguments,
  };
}

__PACKAGE__->meta->make_immutable;
1;
