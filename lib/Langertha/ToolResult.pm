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
JSON-encode it; formats that take structured blocks (Anthropic) embed it as-is;
formats that want plain text (Gemini, Hermes) flatten the text parts.

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

# Shared encoder, byte-identical to the engines' Role::JSON instance.
my $JSON = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );

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
  return {
    role    => 'tool',
    call_id => $self->id,
    content => $JSON->encode( $self->content ),
  };
}

sub to_anthropic {
  my ($self) = @_;
  return {
    type        => 'tool_result',
    tool_use_id => $self->id,
    content     => $self->content,
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
