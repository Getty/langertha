package Langertha::Tool;
# ABSTRACT: Immutable canonical tool definition with cross-provider format conversion
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );
use JSON::MaybeXS;

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
  $class->_croak_unless_function_tool($hash);
  return $class->from_openai($hash)    if ( $hash->{type} // '' ) eq 'function';
  return $class->from_mcp($hash)       if ref( $hash->{inputSchema} )  eq 'HASH';
  return $class->from_anthropic($hash) if ref( $hash->{input_schema} ) eq 'HASH';
  return $class->from_gemini($hash)    if ref( $hash->{parameters} )   eq 'HASH';
  # Last resort: name-only / schemaless
  return $class->from_anthropic($hash);
}

# Only function tools pass this door; since k210 (ADR 0001) everything else
# croaks instead of being dropped or turned into a function tool. The decision
# is classify()'s -- the one source of truth, also used by
# Role::ResponsesCompatible and by sibling callers that must not croak.
sub _croak_unless_function_tool {
  my ($class, $hash) = @_;
  my ( $category, $wire, $label ) = $class->classify($hash);
  return if $category eq 'function';
  my $tail = '(refusing to drop it or send it as a function tool)';
  croak "Langertha::Tool: '$label' is a server-side tool ($wire), and "
    . "server-side tools are not supported yet $tail"
    if $category eq 'server';
  croak "Langertha::Tool: '$label' is a client-executed built-in tool ($wire), "
    . "not a server tool, and Langertha cannot run it $tail"
    if $category eq 'client_builtin';
  croak "Langertha::Tool: unsupported tool type '$label': not a function tool $tail"
    if length( $hash->{type} // '' );
  croak "Langertha::Tool: tool hash has no type and no name (keys: $label): "
    . "not a function tool $tail";
}

# Built-in tools, recognised explicitly per wire (spec k206 section 3.4,
# llm-advisor against the provider references, 2026-09-25). Typed wires match
# on `type` (plus `execution` / `environment` where that decides who runs it);
# Gemini's built-ins are keyed, not typed ({ google_search => {} }), in both
# snake and camel case (ADR 0018). Documentation-derived, not capture-verified.
my %RESPONSES_SERVER_TYPE = map { $_ => 1 } qw(
  web_search file_search code_interpreter image_generation mcp
  x_search collections_search
);
my %RESPONSES_CLIENT_TYPE = map { $_ => 1 } qw(
  local_shell computer computer_use_preview apply_patch
);
my @GEMINI_SERVER_KEY = qw(
  google_search googleSearch google_search_retrieval googleSearchRetrieval
  code_execution codeExecution url_context urlContext google_maps googleMaps
  enterprise_web_search enterpriseWebSearch file_search fileSearch retrieval
);
my @GEMINI_CLIENT_KEY = qw( computer_use computerUse );

# ($category, $wire) for a recognised built-in, else ().
sub _builtin_kind {
  my ($hash) = @_;
  my $type = $hash->{type} // '';
  if ( length $type ) {
    if ( $type eq 'tool_search' ) {
      return ( ( $hash->{execution} // '' ) eq 'client' ? 'client_builtin' : 'server', 'responses' );
    }
    if ( $type eq 'shell' ) {
      my $env = ref $hash->{environment} eq 'HASH' ? ( $hash->{environment}{type} // '' ) : '';
      return ( client_builtin => 'responses' ) if $env eq 'local';
      return ( server         => 'responses' ) if $env =~ /\Acontainer_/;
      return ();
    }
    return ( server => 'responses' )
      if $RESPONSES_SERVER_TYPE{$type}
      || $type =~ /\Aweb_search_(?:preview|\d{4}_\d{2}_\d{2}\z)/;
    return ( client_builtin => 'responses' ) if $RESPONSES_CLIENT_TYPE{$type};
    return ( server => 'anthropic' )
      if $type eq 'mcp_toolset'
      || $type =~ /\A(?:web_search|web_fetch|code_execution|tool_search_tool_\w+?)_\d{8}\z/;
    return ( client_builtin => 'anthropic' )
      if $type =~ /\A(?:bash|text_editor|computer|memory)_\d{8}\z/;
    return ();
  }
  for my $key (@GEMINI_SERVER_KEY) { return ( server => 'gemini' ) if exists $hash->{$key} }
  for my $key (@GEMINI_CLIENT_KEY) { return ( client_builtin => 'gemini' ) if exists $hash->{$key} }
  return ();
}

=method classify

  my $category = Langertha::Tool->classify( $tool_hash );
  my $category = Langertha::Tool->classify( $tool_hash, 'responses' );
  my ( $category, $wire, $label ) = Langertha::Tool->classify( $tool_hash );

Says what kind of tool definition C<$tool_hash> is, without croaking. Use it
where a tool list comes from someone else, such as a gateway that must answer
a bad client request with a 400 instead of dying: C<from_hash>,
C<from_list> and C<format_list> croak on every category except
C<function>, and they take that decision from this method.

The category is one of:

=over 4

=item C<function>

A function tool C<from_hash> translates: a C<Langertha::Tool>, a hash
without C<type> that has a C<name> (canonical, MCP, Gemini declaration,
Anthropic client tool), C<< type => 'function' >> (OpenAI, nested or flat),
or C<< type => 'custom' >> with an C<input_schema> (Anthropic's explicit
client tool).

=item C<server>

A known provider built-in that the provider runs, for example
C<web_search> (Responses), C<web_search_20250305> (Anthropic) or
C<< { google_search => {} } >> (Gemini). Langertha does not support
server-side tools yet.

=item C<client_builtin>

A known provider built-in that the I<client> has to run and Langertha
cannot, for example C<local_shell>, C<computer_use_preview>, C<apply_patch>,
a C<shell> with a local environment, a C<tool_search> with
C<< execution => 'client' >> (Responses), C<bash_20250124> (Anthropic) or
C<computer_use> (Gemini).

=item C<foreign>

Only with C<$fmt>: a C<server> or C<client_builtin> tool of a different
wire than C<$fmt>.

=item C<unknown>

Anything else: a C<type> Langertha does not recognise (including OpenAI's
C<custom> without C<input_schema> and C<namespace>), a hash with neither
C<type> nor C<name> (such as C<< { functionDeclarations => [...] } >>), or
not a hash at all. A wire that takes native items verbatim (the Responses
envelope) passes a typed C<unknown> through to the provider.

=back

C<$fmt> is a C<tool_wire_format> (C<responses>, C<anthropic>, C<gemini>, ...).
In list context the method also returns the wire the built-in belongs to
(C<undef> for C<function> and C<unknown>) and a label: the C<type>, the
Gemini key, or, for an untyped C<unknown>, its keys. The per-wire lists are
taken from the provider documentation and are not verified against live
responses.

=cut

sub classify {
  my ( $class, $hash, $fmt ) = @_;
  my @none = ( undef, undef );
  if ( ref($hash) && eval { $hash->isa(__PACKAGE__) } ) {
    return wantarray ? ( 'function', @none ) : 'function';
  }
  unless ( ref($hash) eq 'HASH' ) {
    return wantarray ? ( 'unknown', undef, ref($hash) || 'non-reference' ) : 'unknown';
  }
  my $type = $hash->{type} // '';
  my ( $category, $wire ) = _builtin_kind($hash);
  my $label = length $type ? $type
    : $category ? ( grep { exists $hash->{$_} } @GEMINI_SERVER_KEY, @GEMINI_CLIENT_KEY )[0]
    : undef;
  if ($category) {
    $category = 'foreign' if defined $fmt && $wire ne $fmt;
  }
  elsif ( $type eq 'function'
    || ( $type eq 'custom' && ref( $hash->{input_schema} ) eq 'HASH' )
    || ( $type eq '' && !ref( $hash->{name} ) && length( $hash->{name} // '' ) ) ) {
    $category = 'function';
    $label    = undef;
  }
  else {
    $category = 'unknown';
    $label  //= join( ',', sort keys %$hash ) || '(empty)';
  }
  return wantarray ? ( $category, $wire, $label ) : $category;
}

# Build from a list of any-shape tool definitions. A hash that is not a function
# tool croaks in from_hash (k210); only a non-reference is still skipped.
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
  my $schema = $self->input_schema;
  return {
    name         => $self->name,
    description  => $self->description,
    input_schema => $schema,
    # Strict tool use (GA, no beta header): guarantees tool_use.input validates
    # exactly against input_schema. Anthropic requires a closed schema for it —
    # additionalProperties:false plus a non-empty required list — so we only
    # emit strict:true where the schema author opted into that shape, and stay
    # silent (and lenient) otherwise. Emitting strict on an open schema 400s.
    ( _schema_is_strict($schema) ? ( strict => JSON->true ) : () ),
  };
}

# True when input_schema is closed enough for Anthropic strict tool use:
# additionalProperties explicitly false and a non-empty required array.
sub _schema_is_strict {
  my ($schema) = @_;
  return 0 unless ref($schema) eq 'HASH';
  return 0 unless exists $schema->{additionalProperties};
  return 0 if $schema->{additionalProperties};   # true / truthy -> open schema
  return 0 unless ref($schema->{required}) eq 'ARRAY' && @{$schema->{required}};
  return 1;
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

# Make the object transparent to any JSON encoder configured with
# convert_blessed => 1 (the house default, see Langertha::Plugin::Langfuse).
# to_hash is the complete canonical representation, so this is a plain
# delegator — nothing is dropped.
sub TO_JSON { shift->to_hash }

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
