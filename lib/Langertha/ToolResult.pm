package Langertha::ToolResult;
# ABSTRACT: Immutable canonical result of executing one tool, with cross-provider conversion
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );
use JSON::MaybeXS;

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
... } ]>). Formats that need an opaque string (OpenAI, Ollama, OpenAI Responses)
JSON-encode it; formats that want plain text (Gemini, Hermes) flatten the text
parts.

Anthropic takes structured blocks, so each MCP block is mapped onto one: text
keeps only C<text> (and C<cache_control>); an image, or an embedded resource
whose blob is an image, becomes a base64 C<image> (JPEG, PNG, GIF, WebP); a PDF
blob becomes a base64 C<document>; a C<text/*> resource, or one without a MIME
type, becomes a text C<document>. Anthropic-native C<image> / C<document> blocks
(with a C<source>) and C<search_result> pass through. Everything else --
C<resource_link>, audio, other MIME types -- becomes a text placeholder naming
type, MIME type and URI, never the payload. Empty content goes out as the
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

The tool's name. Used by formats that key results by name (Gemini, Hermes).

=cut

has id => (
  is      => 'ro',
  isa     => 'Str',
  default => '',
);

=attr id

The provider call id this result answers (C<tool_call_id> / C<tool_use_id> /
C<call_id>). May be empty for formats that don't correlate by id.

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

The MCP C<structuredContent> of the tool's output, if any. Anthropic sends it,
JSON-encoded, as the result string when C<content> is empty.

=cut

# Shared encoder for result payloads that ride as a JSON *string* inside the
# request body (or inside hermes text): characters, not bytes. The transport
# (Role::JSON) encodes the whole body to UTF-8 once; a byte string here would be
# encoded twice ("Köln" -> "KÃ¶ln"). Same key order as Role::JSON. -- karr k252
my $JSON = JSON::MaybeXS->new( utf8 => 0, canonical => 1 );

# Flatten the MCP content array down to a plain text string.
sub _text {
  my ($self) = @_;
  return join( '', map { $_->{text} // '' } @{ $self->content } );
}

# --- Serializers to per-provider result blocks ---

sub to_openai {
  my ($self) = @_;
  return {
    role         => 'tool',
    tool_call_id => $self->id,
    content      => $JSON->encode( $self->content ),
  };
}

sub to_ollama {
  my ($self) = @_;
  return {
    role    => 'tool',
    content => $JSON->encode( $self->content ),
  };
}

sub to_responses {
  my ($self) = @_;
  # A Responses API input item, not a chat message: the wire discriminates on
  # `type`, carries the payload in `output`, and has no `role` at all.
  return {
    type    => 'function_call_output',
    call_id => $self->id,
    output  => $JSON->encode( $self->content ),
  };
}

# --- MCP content -> Anthropic tool_result content (karr k326) ---
#
# Anthropic's tool_result takes text | image | document | search_result blocks
# and rejects unknown fields, so MCP blocks are mapped, not embedded. The mapping
# follows anthropic-sdk-python lib/tools/mcp.py, except that nothing dies inside
# the tool loop: what Anthropic cannot carry (audio, resource_link, unsupported
# MIME types) becomes a text placeholder naming type, MIME and URI -- never the
# base64 payload.

my %ANTHROPIC_IMAGE_MIME = map { $_ => 1 } qw( image/jpeg image/png image/gif image/webp );

sub _anthropic_placeholder {
  my ( $type, $mime, $uri ) = @_;
  my @parts = ( "[$type]", grep { defined && length } $mime, ( defined $uri ? "<$uri>" : () ) );
  return { type => 'text', text => join( ' ', @parts ) };
}

sub _anthropic_image {
  my ( $mime, $data ) = @_;
  return { type => 'image', source => { type => 'base64', media_type => $mime, data => $data } };
}

sub _anthropic_resource {
  my ($res) = @_;
  $res = {} unless ref $res eq 'HASH';
  my $mime = $res->{mimeType};
  if ( defined $res->{text} ) {
    return { type => 'document',
      source => { type => 'text', media_type => 'text/plain', data => $res->{text} } }
      if !defined $mime || $mime =~ m{\Atext/};
  }
  elsif ( defined $res->{blob} && defined $mime ) {
    return _anthropic_image( $mime, $res->{blob} ) if $ANTHROPIC_IMAGE_MIME{$mime};
    return { type => 'document',
      source => { type => 'base64', media_type => 'application/pdf', data => $res->{blob} } }
      if $mime eq 'application/pdf';
  }
  return _anthropic_placeholder( 'resource', $mime, $res->{uri} );
}

sub _anthropic_block {
  my ($block) = @_;
  return _anthropic_placeholder('unsupported') unless ref $block eq 'HASH';
  my $type = $block->{type} // '';
  if ( $type eq 'text' ) {
    return {
      type => 'text',
      text => ( $block->{text} // '' ),
      ( exists $block->{cache_control} ? ( cache_control => $block->{cache_control} ) : () ),
    };
  }
  # Already an Anthropic block (a caller built it for this wire): keep it.
  return $block
    if ( ( $type eq 'image' || $type eq 'document' ) && ref $block->{source} eq 'HASH' )
    || $type eq 'search_result';
  if ( $type eq 'image' ) {
    my $mime = $block->{mimeType} // '';
    return _anthropic_image( $mime, $block->{data} ) if $ANTHROPIC_IMAGE_MIME{$mime};
    return _anthropic_placeholder( 'image', $mime, $block->{uri} );
  }
  return _anthropic_resource( $block->{resource} ) if $type eq 'resource';
  if ( $type eq 'resource_link' ) {
    my @parts = ( '[resource_link]', grep { defined && length } $block->{name},
      ( defined $block->{uri} ? "<$block->{uri}>" : () ) );
    return { type => 'text', text => join( ' ', @parts ) };
  }
  return _anthropic_placeholder( ( length $type ? $type : 'unsupported' ),
    $block->{mimeType}, $block->{uri} );
}

sub _anthropic_content {
  my ($self) = @_;
  my @blocks = map { _anthropic_block($_) } @{ $self->content };
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
  return {
    functionResponse => {
      name     => $self->name,
      response => { result => $self->_text },
    },
  };
}

sub to_hermes {
  my ( $self, %opts ) = @_;
  my $tag = $opts{response_tag} // 'tool_response';
  return "<${tag}>\n"
    . $JSON->encode( { name => $self->name, content => $self->_text } )
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
