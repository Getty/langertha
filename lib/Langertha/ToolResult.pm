package Langertha::ToolResult;
# ABSTRACT: Immutable canonical result of executing one tool, with cross-provider conversion
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );
use JSON::MaybeXS;
use MIME::Base64 ();
use Encode ();

=head1 SYNOPSIS

    use Langertha::ToolResult;

    my $result = Langertha::ToolResult->new(
        name     => 'get_weather',
        id       => 'call_abc',
        content  => [ { type => 'text', text => 'Sunny, 22C' } ],
        is_error => 0,
    );

    my $block = $result->to('anthropic');
    # { type => 'tool_result', tool_use_id => 'call_abc', content => [...] }

=head1 DESCRIPTION

Canonical, provider-neutral result of a single tool execution. Serializes to
the per-provider result I<block> via C<to($fmt)> — one block per result. The
surrounding message envelope (arity, the assistant echo of the prior turn) is
assembled by L<Langertha::Role::Tools>, not here: a ToolResult knows only its
own block shape.

The C<content> is the MCP-style content array (C<[ { type => 'text', text =>
... } ]>). OpenAI, OpenAI Responses, Ollama and Hermes send it as one string:
text parts joined with C<"\n">, an embedded text resource as its text, a
C<text/*> blob decoded as UTF-8, a C<resource_link> as
C<[resource_link] name E<lt>uriE<gt>>, and an image, audio or binary blob as a
placeholder such as C<[image] image/png (12345 bytes)> -- never the base64
payload. Gemini sends that string as C<< { result => ... } >>, or the
L</structured_content> object itself when there is one.

Anthropic takes structured blocks, so each MCP block is mapped onto one: text
keeps only C<text> (and C<cache_control>); an image, or an embedded resource
whose blob is an image, becomes a base64 C<image> (JPEG, PNG, GIF, WebP); a PDF
blob becomes a base64 C<document>; a text resource (whatever its MIME type) or a
C<text/*> blob becomes a text C<document>. Anthropic-native C<image> /
C<document> blocks (with a C<source>) and C<search_result> pass through.
Everything else -- C<resource_link>, audio, other MIME types -- becomes the same
text placeholder, naming type, MIME type, URI and size.

On every string wire and on Anthropic, empty content goes out as the
JSON-encoded L</structured_content>, or as C<''>.

Not every block is a chat message: the OpenAI Responses block is an C<input>
I<item> discriminated by C<type> (C<function_call_output>), carrying its payload
in C<output> and no C<role> at all.

=cut

has name => (
  is      => 'ro',
  isa     => 'Str',
  default => '',
);

=attr name

The tool's name. Used by formats that key results by name (Gemini, Hermes,
Ollama's C<tool_name>).

=cut

has id => (
  is      => 'ro',
  isa     => 'Str',
  default => '',
);

=attr id

The provider call id this result answers (C<tool_call_id> / C<tool_use_id> /
C<call_id>; Gemini's C<functionResponse.id>, Ollama's C<tool_call_id>). May be
empty; Gemini and Ollama then send no id at all.

=cut

has content => (
  is      => 'ro',
  isa     => 'ArrayRef',
  default => sub { [] },
);

=attr content

The MCP-style content array of the tool's output, e.g.
C<[ { type => 'text', text => '...' } ]>.

=cut

has is_error => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

=attr is_error

Boolean. True when the tool execution failed; surfaced on formats that carry an
error flag (Anthropic C<is_error>).

=cut

has structured_content => (
  is        => 'ro',
  predicate => 'has_structured_content',
);

=attr structured_content

The MCP C<structuredContent> of the tool's output, if any. Sent JSON-encoded as
the result string when C<content> is empty; Gemini sends the object as its
C<functionResponse.response> whenever it is present.

=cut

# Shared encoder for result payloads that ride as a JSON *string* inside the
# request body (or inside hermes text): characters, not bytes. The transport
# (Role::JSON) encodes the whole body to UTF-8 once; a byte string here would be
# encoded twice ("Köln" -> "KÃ¶ln"). Same key order as Role::JSON. -- karr k252
my $JSON = JSON::MaybeXS->new( utf8 => 0, canonical => 1 );

# --- MCP content normalizer, shared by every format (karr k326, k336) ---
#
# One pass over the MCP content array yields neutral items; each format renders
# them. Kinds:
#   text      a text block (keeps cache_control, for Anthropic)
#   document  text from an embedded resource (whatever its MIME type), or a
#             text/* blob decoded as UTF-8
#   blob      a base64 payload (image, audio, binary resource) with its MIME
#   native    an Anthropic-native block a caller built for that wire
#   note      a ready text placeholder (resource_link, non-hash blocks)
# A blob the wire cannot carry becomes a placeholder naming type, MIME, URI and
# decoded size -- never the base64 payload.

sub _b64_size {
  my ($data) = @_;
  return undef unless defined $data && !ref $data;
  ( my $b64 = $data ) =~ s/\s+//g;
  my $pad = () = $b64 =~ /=/g;
  return int( length($b64) * 3 / 4 ) - $pad;
}

sub _placeholder {
  my ( $type, $mime, $uri, $data ) = @_;
  my $size = _b64_size($data);
  return join( ' ', "[$type]", grep { defined && length } $mime,
    ( defined $uri ? "<$uri>" : () ), ( defined $size ? "($size bytes)" : () ) );
}

sub _mcp_resource {
  my ($res) = @_;
  $res = {} unless ref $res eq 'HASH';
  my $mime = $res->{mimeType};
  return { kind => 'document', text => $res->{text} } if defined $res->{text};
  if ( defined $res->{blob} && defined $mime && $mime =~ m{\Atext/} ) {
    my $bytes = MIME::Base64::decode_base64( $res->{blob} );
    return { kind => 'document',
      text => Encode::decode( 'UTF-8', $bytes, Encode::FB_DEFAULT() ) };
  }
  return { kind => 'blob', type => 'resource', mime => $mime, uri => $res->{uri},
    data => $res->{blob} };
}

sub _mcp_item {
  my ($block) = @_;
  return { kind => 'note', text => _placeholder('unsupported') } unless ref $block eq 'HASH';
  my $type = $block->{type} // '';
  if ( $type eq 'text' ) {
    return { kind => 'text', text => ( $block->{text} // '' ),
      ( exists $block->{cache_control} ? ( cache_control => $block->{cache_control} ) : () ) };
  }
  return { kind => 'native', block => $block }
    if ( ( $type eq 'image' || $type eq 'document' ) && ref $block->{source} eq 'HASH' )
    || $type eq 'search_result';
  return _mcp_resource( $block->{resource} ) if $type eq 'resource';
  if ( $type eq 'resource_link' ) {
    return { kind => 'note', text => join( ' ', '[resource_link]',
      grep { defined && length } $block->{name},
      ( defined $block->{uri} ? "<$block->{uri}>" : () ) ) };
  }
  return { kind => 'blob', type => ( length $type ? $type : 'unsupported' ),
    mime => $block->{mimeType}, uri => $block->{uri}, data => $block->{data} };
}

sub _mcp_items {
  my ($self) = @_;
  return map { _mcp_item($_) } @{ $self->content };
}

# One item as text for the string wires.
sub _string_item {
  my ($item) = @_;
  my $kind = $item->{kind};
  return _placeholder( @{$item}{qw( type mime uri data )} ) if $kind eq 'blob';
  return $item->{text} unless $kind eq 'native';
  # An Anthropic-native block on a string wire: a text document gives its
  # text, anything else a placeholder.
  my $native = $item->{block};
  my $src    = ref $native->{source} eq 'HASH' ? $native->{source} : {};
  return $src->{data} if ( $src->{type} // '' ) eq 'text' && defined $src->{data};
  return _placeholder( $native->{type}, $src->{media_type}, $src->{url} );
}

# The whole result as one string: parts joined with "\n"; empty content falls
# back to the JSON-encoded structured_content, else ''.
sub _string_content {
  my ($self) = @_;
  my @parts = map { _string_item($_) } $self->_mcp_items;
  return join( "\n", @parts ) if @parts;
  return $JSON->encode( $self->structured_content ) if $self->has_structured_content;
  return '';
}

# --- Serializers to per-provider result blocks ---

sub to_openai {
  my ($self) = @_;
  # The chat tool message takes a string (or text parts only) -- karr k336.
  return {
    role         => 'tool',
    tool_call_id => $self->id,
    content      => $self->_string_content,
  };
}

sub to_ollama {
  my ($self) = @_;
  # Ollama's Message carries tool_name and tool_call_id (both omitempty); with
  # same-name parallel calls they are what correlates a result (karr k328).
  return {
    role      => 'tool',
    tool_name => $self->name,
    ( length( $self->id ) ? ( tool_call_id => $self->id ) : () ),
    content   => $self->_string_content,
  };
}

sub to_responses {
  my ($self) = @_;
  # A Responses API input item, not a chat message: the wire discriminates on
  # `type`, carries the payload in `output`, and has no `role` at all.
  return {
    type    => 'function_call_output',
    call_id => $self->id,
    output  => $self->_string_content,
  };
}

# --- Anthropic tool_result content (karr k326) ---
#
# Anthropic's tool_result takes text | image | document | search_result blocks
# and rejects unknown fields, so MCP blocks are mapped, not embedded. The mapping
# follows anthropic-sdk-python lib/tools/mcp.py, except that nothing dies inside
# the tool loop: what Anthropic cannot carry (audio, resource_link, unsupported
# MIME types) becomes a text placeholder.

my %ANTHROPIC_IMAGE_MIME = map { $_ => 1 } qw( image/jpeg image/png image/gif image/webp );

sub _anthropic_block {
  my ($item) = @_;
  my $kind = $item->{kind};
  return $item->{block} if $kind eq 'native';
  if ( $kind eq 'text' ) {
    return { type => 'text', text => $item->{text},
      ( exists $item->{cache_control} ? ( cache_control => $item->{cache_control} ) : () ) };
  }
  return { type => 'text', text => $item->{text} } if $kind eq 'note';
  if ( $kind eq 'document' ) {
    return { type => 'document',
      source => { type => 'text', media_type => 'text/plain', data => $item->{text} } };
  }
  my ( $type, $mime, $data ) = ( $item->{type}, $item->{mime} // '', $item->{data} );
  if ( defined $data && ( $type eq 'image' || $type eq 'resource' ) ) {
    return { type => 'image', source => { type => 'base64', media_type => $mime, data => $data } }
      if $ANTHROPIC_IMAGE_MIME{$mime};
    return { type => 'document',
      source => { type => 'base64', media_type => 'application/pdf', data => $data } }
      if $type eq 'resource' && $mime eq 'application/pdf';
  }
  return { type => 'text', text => _placeholder( @{$item}{qw( type mime uri data )} ) };
}

sub _anthropic_content {
  my ($self) = @_;
  my @blocks = map { _anthropic_block($_) } $self->_mcp_items;
  return \@blocks if @blocks;
  return $JSON->encode( $self->structured_content ) if $self->has_structured_content;
  return '';
}

sub to_anthropic {
  my ($self) = @_;
  return {
    type        => 'tool_result',
    tool_use_id => $self->id,
    content     => $self->_anthropic_content,
    ( $self->is_error ? ( is_error => JSON::MaybeXS::true() ) : () ),
  };
}

sub to_gemini {
  my ($self) = @_;
  # functionResponse.response is a JSON object: the MCP structuredContent when
  # the tool gave one, else the result string under `result` (karr k336).
  my $structured = $self->structured_content;
  return {
    functionResponse => {
      name     => $self->name,
      # Gemini 3 requires the functionCall's id back; 2.5 may send none, and
      # an invented one would match nothing (karr k328).
      ( length( $self->id ) ? ( id => $self->id ) : () ),
      response => ( ref $structured eq 'HASH'
        ? $structured : { result => $self->_string_content } ),
    },
  };
}

sub to_hermes {
  my ( $self, %opts ) = @_;
  my $tag = $opts{response_tag} // 'tool_response';
  return "<${tag}>\n"
    . $JSON->encode( { name => $self->name, content => $self->_string_content } )
    . "\n</${tag}>";
}

# --- Tag-driven dispatch ---

my %TO_METHOD = (
  openai    => 'to_openai',
  anthropic => 'to_anthropic',
  gemini    => 'to_gemini',
  ollama    => 'to_ollama',
  responses => 'to_responses',
  hermes    => 'to_hermes',
);

=method to

    my $block = $result->to($fmt);
    my $block = $result->to('hermes', response_tag => 'fn_response');

Serializes to the result block for the given C<tool_wire_format>. Extra options
are passed through to the per-format serializer (Hermes accepts
C<response_tag>).

=cut

sub to {
  my ( $self, $fmt, %opts ) = @_;
  my $method = $TO_METHOD{ $fmt // '' }
    or croak "Langertha::ToolResult: unknown wire format '" . ( $fmt // '' ) . "'";
  return $self->$method(%opts);
}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::ToolCall> - The invocation a ToolResult answers

=item * L<Langertha::Tool> - The tool definition

=item * L<Langertha::Role::Tools> - Assembles result blocks into the message envelope

=back

=cut

1;
