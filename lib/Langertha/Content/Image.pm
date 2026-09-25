package Langertha::Content::Image;
# ABSTRACT: Canonical image content block with cross-provider conversion
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );
use MIME::Base64 qw( encode_base64 decode_base64 );
use Future;
use Future::AsyncAwait;
use Scalar::Util qw( blessed );

with 'Langertha::Content';

=head1 SYNOPSIS

    use Langertha::Content::Image;

    # From a remote URL
    my $img = Langertha::Content::Image->from_url('https://example.com/cat.jpg');

    # From a local file (media_type sniffed from extension)
    my $img = Langertha::Content::Image->from_file('/tmp/cat.png');

    # From raw bytes
    my $img = Langertha::Content::Image->from_data($bytes, media_type => 'image/jpeg');

    # From an existing base64 string
    my $img = Langertha::Content::Image->from_base64($b64, media_type => 'image/png');

    # Embed in a chat message — Langertha::Role::Chat converts per engine
    my $response = $engine->simple_chat_f({
        role    => 'user',
        content => [ 'What is in this image?', $img ],
    });

=head1 DESCRIPTION

Provider-neutral image block. Carries either a remote URL, a base64 payload,
or both, plus an IANA C<media_type>. Serializes to these vision-chat wire
formats:

=over

=item * OpenAI chat completions — C<{ type => 'image_url', image_url => { url => ... } }>

=item * Anthropic messages — C<{ type => 'image', source => { type => 'url' | 'base64', ... } }>

=item * Google Gemini — C<{ inline_data => { mime_type => ..., data => <base64> } }>

=item * Open-Responses — C<{ type => 'input_image', image_url => <url or data: URL> }>

=item * Ollama native — the raw base64 string, for the message C<images> array

=item * LM Studio native — C<{ type => 'image', data_url => <data: URL> }>

=back

Gemini, Ollama native and LM Studio native require inline data, so their
serializers transparently download a remote URL on first call (cached on the
object). Engines whose OpenAI-compatible endpoint rejects remote image URLs
get the same treatment through C<< to_openai( inline => 1 ) >>. On the C<_f>
methods of L<Langertha::Role::Chat> the download happens earlier, through the
engine's async HTTP backend (L</ensure_base64_f>), so the serializers find the
payload cached and do not block the event loop.

=cut

has url => (
  is => 'ro',
  isa => 'Maybe[Str]',
  predicate => 'has_url',
);

=attr url

Remote HTTP(S) URL of the image. May be passed through directly (OpenAI,
Anthropic) or auto-downloaded and base64-encoded (Gemini).

=cut

has base64 => (
  is => 'rw',
  isa => 'Maybe[Str]',
  predicate => 'has_base64',
);

=attr base64

The base64-encoded image payload (no C<data:> URL prefix). Can be supplied
at construction, or populated lazily when a provider that requires inline
data (Gemini) is targeted.

=cut

has media_type => (
  is => 'rw',
  isa => 'Maybe[Str]',
  predicate => 'has_media_type',
);

=attr media_type

IANA media type (C<image/jpeg>, C<image/png>, C<image/gif>, C<image/webp>).
Required for base64 payloads on Anthropic and Gemini. Sniffed from the file
extension by C<from_file> and from the URL path by C<from_url>.

=cut

sub BUILD {
  my ($self) = @_;
  croak "Langertha::Content::Image requires url, base64, or data"
    unless $self->has_url || $self->has_base64;
}

# --- Constructors ---

sub from_url {
  my ( $class, $url, %extra ) = @_;
  croak "from_url requires a URL" unless defined $url && length $url;
  my $media_type = $extra{media_type} // _sniff_media_type($url);
  return $class->new(
    url => $url,
    ( defined $media_type ? ( media_type => $media_type ) : () ),
  );
}

=method from_url

    my $img = Langertha::Content::Image->from_url($url);
    my $img = Langertha::Content::Image->from_url($url, media_type => 'image/jpeg');

Builds an image block referencing a remote URL. Media type is sniffed from
the URL extension when not provided.

=cut

sub from_file {
  my ( $class, $path, %extra ) = @_;
  croak "from_file requires a path" unless defined $path && length $path;
  croak "from_file: $path not found" unless -f $path;
  open my $fh, '<:raw', $path or croak "open $path: $!";
  my $bytes = do { local $/; <$fh> };
  close $fh;
  my $media_type = $extra{media_type} // _sniff_media_type($path);
  croak "from_file: cannot determine media_type for $path"
    unless defined $media_type;
  return $class->new(
    base64     => encode_base64($bytes, ''),
    media_type => $media_type,
  );
}

=method from_file

    my $img = Langertha::Content::Image->from_file('/tmp/cat.png');

Reads a local file, base64-encodes it, and sniffs the media type from the
extension (unless C<media_type> is passed).

=cut

sub from_data {
  my ( $class, $bytes, %extra ) = @_;
  croak "from_data requires bytes" unless defined $bytes;
  croak "from_data requires media_type" unless defined $extra{media_type};
  return $class->new(
    base64     => encode_base64($bytes, ''),
    media_type => $extra{media_type},
  );
}

=method from_data

    my $img = Langertha::Content::Image->from_data($bytes, media_type => 'image/jpeg');

Builds an image block from raw bytes. C<media_type> is required.

=cut

sub from_base64 {
  my ( $class, $b64, %extra ) = @_;
  croak "from_base64 requires a base64 string" unless defined $b64 && length $b64;
  croak "from_base64 requires media_type" unless defined $extra{media_type};
  return $class->new(
    base64     => $b64,
    media_type => $extra{media_type},
  );
}

=method from_base64

    my $img = Langertha::Content::Image->from_base64($b64, media_type => 'image/png');

Builds an image block from an existing base64 string.

=cut

# --- Base64 materialization ---

sub ensure_base64 {
  my ($self) = @_;
  return $self->base64 if $self->has_base64;
  croak "ensure_base64: no url to fetch" unless $self->has_url;

  require LWP::UserAgent;
  my $ua = LWP::UserAgent->new(
    agent   => 'Langertha-Content-Image/'.$VERSION,
    timeout => 30,
  );
  return $self->_inline_fetched( $ua->get($self->url) );
}

# Async twin of ensure_base64 (karr k274): the GET goes through $http, any
# client with the async do_request contract (ADR 0027) -- the engine's
# _async_http on the _f paths, so a URL image never blocks the event loop on
# LWP. A transport failure and an error status fail the Future with the text
# ensure_base64 croaks.
async sub ensure_base64_f {
  my ( $self, $http ) = @_;
  return $self->base64 if $self->has_base64;
  croak "ensure_base64_f: no url to fetch" unless $self->has_url;
  croak "ensure_base64_f requires a client with do_request"
    unless blessed($http) && $http->can('do_request');

  my $url = $self->url;
  require HTTP::Request;
  my $request = HTTP::Request->new( GET => $url,
    [ 'User-Agent' => 'Langertha-Content-Image/'.$VERSION ] );
  my $response = await $http->do_request( request => $request )->else( sub {
    my ($err) = @_;
    $err =~ s/\s+\z//;
    Future->fail("ensure_base64: failed to fetch $url: $err\n");
  } );
  return $self->_inline_fetched($response);
}

# Stores a fetched HTTP::Response as the inline payload (both doors above).
sub _inline_fetched {
  my ( $self, $response ) = @_;
  croak "ensure_base64: failed to fetch ".$self->url.": ".$response->status_line
    unless $response->is_success;

  $self->base64(encode_base64($response->decoded_content(charset => 'none'), ''));
  unless ($self->has_media_type) {
    my $ct = $response->header('Content-Type') // '';
    $ct =~ s/;.*$//;
    $ct =~ s/^\s+|\s+$//g;
    $self->media_type($ct) if length $ct;
  }
  return $self->base64;
}

=method ensure_base64

    my $b64 = $img->ensure_base64;

Returns the base64 payload, fetching the URL over HTTP if necessary.
Populates C<media_type> from the response C<Content-Type> header when the
image was URL-only. Caches the result on the object.

=cut

=method ensure_base64_f

    my $b64 = await $img->ensure_base64_f($http);

The async L</ensure_base64>: returns a L<Future> of the base64 payload and
fetches the URL through C<$http>, any client that answers the async
C<do_request> contract (L<Langertha::Role::AsyncHTTP>), instead of a blocking
L<LWP::UserAgent>. A transport error or a non-success status fails the Future.
The C<_f> methods of L<Langertha::Role::Chat> call it with the engine's backend
for every URL image the engine has to inline, before the request is built.

=cut

# --- Serializers ---

sub data_url {
  my ($self) = @_;
  $self->ensure_base64;
  return sprintf('data:%s;base64,%s',
    ($self->media_type // 'application/octet-stream'),
    $self->base64,
  );
}

=method data_url

    my $uri = $img->data_url;   # data:image/png;base64,...

Returns the image as a C<data:> URL, fetching a URL-only image first (see
L</ensure_base64>). The media type falls back to C<application/octet-stream>.

=cut

# The image as one string for wires that take "URL or data URL" in one field.
# inline => 1 forces the data URL (fetching a URL-only image first, like
# to_gemini) for endpoints that reject remote image URLs (karr k267).
sub _url_or_data_url {
  my ( $self, %opt ) = @_;
  return $self->url if $self->has_url && !$opt{inline};
  return $self->data_url;
}

sub to_openai {
  my ( $self, %opt ) = @_;
  return { type => 'image_url', image_url => { url => $self->_url_or_data_url(%opt) } };
}

=method to_openai

    my $block = $img->to_openai;
    # { type => 'image_url', image_url => { url => ... } }
    my $block = $img->to_openai( inline => 1 );   # always a data: URL

Serializes to the OpenAI chat-completions image block. Uses the URL when
available, otherwise emits a C<data:> URL from the base64 payload. With
C<< inline => 1 >> it always emits the C<data:> URL, fetching a URL-only image
first; L<Langertha::Role::Chat> passes it for engines whose endpoint rejects
remote image URLs.

=cut

sub to_responses {
  my ( $self, %opt ) = @_;
  return { type => 'input_image', image_url => $self->_url_or_data_url(%opt) };
}

=method to_responses

    my $block = $img->to_responses;
    # { type => 'input_image', image_url => 'https://...' }   (or a data: URL)

Serializes to the Open-Responses C<input_image> part (OpenAI C</v1/responses>,
Perplexity C</v1/agent>). C<image_url> is a plain string, not an object: the
URL when available, otherwise a C<data:> URL. Takes C<< inline => 1 >> like
L</to_openai>.

=cut

sub to_ollama {
  my ($self) = @_;
  return $self->ensure_base64;
}

=method to_ollama

    my $b64 = $img->to_ollama;

Returns the raw base64 payload (no C<data:> prefix) for one entry of the
Ollama native C</api/chat> message C<images> array. Fetches a URL-only image
first, because that wire takes no image URLs.

=cut

sub to_lmstudio {
  my ($self) = @_;
  return { type => 'image', data_url => $self->data_url };
}

=method to_lmstudio

    my $item = $img->to_lmstudio;
    # { type => 'image', data_url => 'data:image/png;base64,...' }

Serializes to an LM Studio native C</api/v1/chat> C<input> image item. That
wire takes only base64 data URLs, so a URL-only image is fetched first.

=cut

sub to_anthropic {
  my ($self) = @_;
  if ($self->has_url) {
    return {
      type   => 'image',
      source => { type => 'url', url => $self->url },
    };
  }
  croak "to_anthropic: base64 image requires media_type"
    unless $self->has_media_type;
  return {
    type   => 'image',
    source => {
      type       => 'base64',
      media_type => $self->media_type,
      data       => $self->base64,
    },
  };
}

=method to_anthropic

    my $block = $img->to_anthropic;
    # { type => 'image', source => { type => 'url', url => ... } }
    # or
    # { type => 'image', source => { type => 'base64', media_type => ..., data => ... } }

Serializes to the Anthropic messages image block. Prefers a URL source
when available; otherwise emits an inline base64 source (C<media_type>
required).

=cut

sub to_gemini {
  my ($self) = @_;
  $self->ensure_base64;
  croak "to_gemini: image requires media_type"
    unless $self->has_media_type;
  return {
    inline_data => {
      mime_type => $self->media_type,
      data      => $self->base64,
    },
  };
}

=method to_gemini

    my $block = $img->to_gemini;
    # { inline_data => { mime_type => ..., data => <base64> } }

Serializes to the Gemini C<inlineData> part. Auto-downloads URL-only
images because Gemini has no URL-fetching equivalent.

=cut

# --- Helpers ---

my %EXT_MAP = (
  jpg  => 'image/jpeg',
  jpeg => 'image/jpeg',
  png  => 'image/png',
  gif  => 'image/gif',
  webp => 'image/webp',
  bmp  => 'image/bmp',
  svg  => 'image/svg+xml',
  heic => 'image/heic',
  heif => 'image/heif',
);

sub _sniff_media_type {
  my ($path) = @_;
  return undef unless defined $path;
  ( my $clean = $path ) =~ s/[?#].*$//;
  if ( $clean =~ /\.([a-zA-Z0-9]+)$/ ) {
    return $EXT_MAP{ lc $1 };
  }
  return undef;
}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Content> - Base role this class implements

=item * L<Langertha::Role::Chat> - Normalizes content blocks per engine during C<chat_messages>

=item * L<Langertha::ToolChoice> - Sibling value object for tool_choice normalization

=back

=cut

1;
