package Langertha::Tool;
# ABSTRACT: Immutable canonical tool definition with cross-provider format conversion
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

has name => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

has description => (
  is      => 'ro',
  isa     => 'Str',
  default => '',
);

has input_schema => (
  is      => 'ro',
  isa     => 'HashRef',
  default => sub { { type => 'object', properties => {} } },
);

sub _empty_schema { { type => 'object', properties => {} } }

# --- Constructors from wire-format hashes ---

sub from_openai {
  my ($class, $hash) = @_;
  return undef unless ref($hash) eq 'HASH';
  return undef unless ($hash->{type} // '') eq 'function';
  my $fn = $hash->{function} || {};
  return undef unless ref($fn) eq 'HASH';
  my $name = $fn->{name} // '';
  return undef unless length $name;
  return $class->new(
    name         => $name,
    description  => ( $fn->{description} // '' ),
    input_schema => ( $fn->{parameters} || $class->_empty_schema ),
  );
}

sub from_anthropic {
  my ($class, $hash) = @_;
  return undef unless ref($hash) eq 'HASH';
  my $name = $hash->{name} // '';
  return undef unless length $name;
  return $class->new(
    name         => $name,
    description  => ( $hash->{description} // '' ),
    input_schema => ( $hash->{input_schema} || $hash->{parameters} || $class->_empty_schema ),
  );
}

# MCP server tool definition: name + description + inputSchema (camelCase).
sub from_mcp {
  my ($class, $hash) = @_;
  return undef unless ref($hash) eq 'HASH';
  my $name = $hash->{name} // '';
  return undef unless length $name;
  return $class->new(
    name         => $name,
    description  => ( $hash->{description} // '' ),
    input_schema => ( $hash->{inputSchema} || $hash->{input_schema} || $class->_empty_schema ),
  );
}

# Gemini functionDeclarations: name + description + parameters (flat).
sub from_gemini {
  my ($class, $hash) = @_;
  return undef unless ref($hash) eq 'HASH';
  my $name = $hash->{name} // '';
  return undef unless length $name;
  return $class->new(
    name         => $name,
    description  => ( $hash->{description} // '' ),
    input_schema => ( $hash->{parameters} || $class->_empty_schema ),
  );
}

# Generic: figure out the wire shape and route accordingly. Order matters —
# we test the most specific markers first.
sub from_hash {
  my ($class, $hash) = @_;
  return $hash if ref($hash) && eval { $hash->isa(__PACKAGE__) };
  return undef unless ref($hash) eq 'HASH';
  return $class->from_openai($hash)    if ( $hash->{type} // '' ) eq 'function';
  return $class->from_mcp($hash)       if ref( $hash->{inputSchema} )  eq 'HASH';
  return $class->from_anthropic($hash) if ref( $hash->{input_schema} ) eq 'HASH';
  return $class->from_gemini($hash)    if ref( $hash->{parameters} )   eq 'HASH';
  # Last resort: name-only / schemaless
  return $class->from_anthropic($hash);
}

# Build from a list of any-shape hashrefs and skip ones that don't parse.
sub from_list {
  my ($class, $list) = @_;
  return [] unless ref($list) eq 'ARRAY';
  my @out;
  for my $item (@$list) {
    my $tool = $class->from_hash($item);
    push @out, $tool if $tool;
  }
  return \@out;
}

# --- Serializers to wire-format hashes ---

sub to_openai {
  my ($self) = @_;
  return {
    type     => 'function',
    function => {
      name        => $self->name,
      description => $self->description,
      parameters  => $self->input_schema,
    },
  };
}

sub to_anthropic {
  my ($self) = @_;
  return {
    name         => $self->name,
    description  => $self->description,
    input_schema => $self->input_schema,
  };
}

sub to_ollama { $_[0]->to_openai }

sub to_gemini {
  my ($self) = @_;
  return {
    name        => $self->name,
    description => $self->description,
    parameters  => $self->input_schema,
  };
}

# OpenAI Responses API: flat tool objects, no {type:'function',function:{...}} wrapper
sub to_responses {
  my ($self) = @_;
  return {
    type        => 'function',
    name        => $self->name,
    description => $self->description,
    parameters  => $self->input_schema,
  };
}

sub to_mcp {
  my ($self) = @_;
  return {
    name        => $self->name,
    description => $self->description,
    inputSchema => $self->input_schema,
  };
}

# Shape used inside OpenAI's response_format => { type=>'json_schema',
# json_schema => { ... } } — and the basis of the chat_f forced-tool
# fallback path.
sub to_json_schema {
  my ($self) = @_;
  return {
    name        => $self->name,
    description => $self->description,
    schema      => $self->input_schema,
  };
}

# Canonical hash (matches the legacy Input::Tools->normalize_tools shape).
sub to_hash {
  my ($self) = @_;
  return {
    name         => $self->name,
    description  => $self->description,
    input_schema => $self->input_schema,
  };
}

# --- Tag-driven dispatch ---

# Maps a tool_wire_format tag to the per-tool serializer method.
my %TO_METHOD = (
  openai    => 'to_openai',
  anthropic => 'to_anthropic',
  gemini    => 'to_gemini',
  ollama    => 'to_ollama',
  responses => 'to_responses',
  mcp       => 'to_mcp',
  hermes    => 'to_mcp',     # Hermes injects raw MCP defs into the prompt as JSON
);

# Serialize this single tool to the given wire format.
sub to {
  my ($self, $fmt) = @_;
  my $method = $TO_METHOD{ $fmt // '' }
    or croak "Langertha::Tool: unknown wire format '" . ( $fmt // '' ) . "'";
  return $self->$method;
}

# Class method: turn a list of any-shape (usually MCP) tool hashrefs into the
# full wire `tools` payload for the given format. Handles collection-level
# shaping (Gemini wraps its declarations) that a per-tool serializer cannot.
sub format_list {
  my ($class, $fmt, $tools) = @_;
  $fmt //= '';
  my @objs = @{ $class->from_list($tools) };
  if ( $fmt eq 'gemini' ) {
    return [ { functionDeclarations => [ map { $_->to_gemini } @objs ] } ];
  }
  return [ map { $_->to($fmt) } @objs ];
}

__PACKAGE__->meta->make_immutable;
1;
