#!/usr/bin/env perl
# ABSTRACT: Test Whisper transcription request generation

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;
use Path::Tiny;

use Langertha::Engine::Whisper;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

my $whisper_testurl = 'http://test.url:12345/v1';
my $whisper = Langertha::Engine::Whisper->new(
  url => $whisper_testurl,
  transcription_model => 'model',
);
my $whisper_request = $whisper->transcription(path(__FILE__)->parent->child('data/testfile')->absolute, language => 'en');
is($whisper_request->uri, $whisper_testurl.'/audio/transcriptions', 'Whisper request uri is correct');
is($whisper_request->method, 'POST', 'Whisper request method is correct');
is($whisper_request->header('Content-Type'), 'multipart/form-data; boundary="XyXLaXyXngXyXerXyXthXyXaXyX"', 'Whisper request Content Type is correct');
my $content = "--XyXLaXyXngXyXerXyXthXyXaXyX
Content-Disposition: form-data; name=\"file\"; filename=\"testfile\"
Content-Type: application/octet-stream

testxxxx
--XyXLaXyXngXyXerXyXthXyXaXyX
Content-Disposition: form-data; name=\"language\"

en
--XyXLaXyXngXyXerXyXthXyXaXyX
Content-Disposition: form-data; name=\"model\"

model
--XyXLaXyXngXyXerXyXthXyXaXyX--
"; $content =~ s/\n/\r\n/g;
is($whisper_request->content, $content, 'Whisper request content is correct');

# karr k286: the multipart body must follow the same rules as the JSON body --
# character strings go out as UTF-8 (a prompt in German must reach the server
# as German, not Latin-1 mojibake or a "content must be bytes" croak), the
# Content-Type boundary is the one the body really uses, and OpenAI's
# multi-valued fields (timestamp_granularities[]) are repeated text parts, not
# file paths to open.
my $file = path(__FILE__)->parent->child('data/testfile')->absolute;
my $boundary = 'XyXLaXyXngXyXerXyXthXyXaXyX';
my $multipart = sub {
  my ( @parts ) = @_;
  my $body = join('', map { "--$boundary\r\n$_\r\n" } @parts)."--$boundary--\r\n";
  return $body;
};

{
  my $req = $whisper->transcription($file, prompt => "Gr\x{fc}\x{df}e \x{2603}");
  ok(!utf8::is_utf8($req->content), 'body with a wide-char prompt is bytes');
  my ($prompt) = $req->content =~ /name="prompt"\r\n\r\n(.*?)\r\n--/s;
  is($prompt, "Gr\xc3\xbc\xc3\x9fe \xe2\x98\x83", 'wide-char prompt is sent UTF-8 encoded');

  my $latin = "Gr\x{fc}\x{df}e";
  utf8::downgrade($latin);    # characters < 0x100 held without the UTF-8 flag
  ($prompt) = $whisper->transcription($file, prompt => $latin)->content =~ /name="prompt"\r\n\r\n(.*?)\r\n--/s;
  is($prompt, "Gr\xc3\xbc\xc3\x9fe", 'Latin-1 range prompt is sent UTF-8 encoded too, as in a JSON body');
}

{
  my $req = $whisper->transcription($file,
    'timestamp_granularities[]' => [qw( word segment )],
    response_format => 'verbose_json',
  );
  is($req->content, $multipart->(
    "Content-Disposition: form-data; name=\"file\"; filename=\"testfile\"\r\nContent-Type: application/octet-stream\r\n\r\ntestxxxx",
    "Content-Disposition: form-data; name=\"model\"\r\n\r\nmodel",
    "Content-Disposition: form-data; name=\"response_format\"\r\n\r\nverbose_json",
    "Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\nword",
    "Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\nsegment",
  ), 'ArrayRef under a [] key becomes repeated text fields, in order');
}

{
  my $req = $whisper->transcription($file, prompt => "x $boundary y");
  my ($used) = $req->header('Content-Type') =~ /boundary="([^"]+)"/;
  isnt($used, $boundary, 'a prompt containing the default boundary forces another one');
  like($req->content, qr/\A--\Q$used\E\r\n/, 'Content-Type boundary is the one the body starts with');
  like($req->content, qr/\r\n--\Q$used\E--\r\n\z/, 'Content-Type boundary is the one the body ends with');
}

{
  my $dir = Path::Tiny->tempdir;
  my $name = "Gr\xc3\xbc\xc3\x9fe \xe2\x98\x83.wav";    # UTF-8 bytes, as readdir/ARGV give them
  $dir->child($name)->spew_raw('abc');
  my $req = $whisper->transcription($dir->child($name)->stringify);
  like($req->content, qr/; filename="\Q$name\E"\r\n/, 'undecoded (byte) path: filename sent unchanged as raw UTF-8');

  my ($body) = $whisper->generate_multipart_body($req,
    file => [ undef, "Gr\x{fc}\x{df}e \x{2603}.wav", Content => 'abc' ],
  );
  like($body, qr/; filename="\Q$name\E"\r\n/, 'decoded (character) filename is sent UTF-8 encoded');
}

# karr k287: simple_transcription($audio_bytes) is documented, so in-memory
# audio must become the file part's content -- never a path handed to open()
# (which croaked "Can't open file RIFF...").
{
  my $audio = "RIFF\0\x01\xff\xfeWAVEdata";
  my $expected = sub {
    my ( $filename ) = @_;
    return $multipart->(
      "Content-Disposition: form-data; name=\"file\"; filename=\"$filename\"\r\nContent-Type: application/octet-stream\r\n\r\n$audio",
      "Content-Disposition: form-data; name=\"model\"\r\n\r\nmodel",
    );
  };
  is($whisper->transcription(\$audio, filename => 'speech.wav')->content, $expected->('speech.wav'),
    'scalar ref: bytes are the part content, filename from the filename option (not a form field)');
  is($whisper->transcription(\$audio)->content, $expected->('audio'),
    'scalar ref without filename: filename defaults to audio');

  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  is($whisper->transcription($audio, filename => 'speech.wav')->content, $expected->('speech.wav'),
    'plain string with a NUL byte is content, as the POD documents');
  is(scalar @warnings, 0, 'and it never reaches open() (no "Invalid \\0 character in pathname")');

  open my $fh, '<', \$audio or die $!;
  is($whisper->transcription($fh, filename => 'speech.wav')->content, $expected->('speech.wav'),
    'filehandle: read to the end, sent as content');

  is($whisper->transcription($file, filename => 'renamed.wav')->content =~ /filename="([^"]+)"/ ? $1 : undef,
    'renamed.wav', 'path with filename option: upload renamed, content still read from the path');

  my $chars = "caf\x{e9} \x{2603}";
  ok(!eval { $whisper->transcription(\$chars); 1 }, 'character string as audio content croaks');
  like($@, qr/audio content must be bytes/, '... with a clear message');
}

# karr k293: $openai->whisper is sold as "the same engine, focused on
# transcription" -- it must not silently fall back to LWP's 180s timeout, the
# TranscriptionBase User-Agent or the default model when the parent says otherwise.
{
  require Langertha::Engine::OpenAI;
  my $openai = Langertha::Engine::OpenAI->new(
    api_key             => 'k',
    user_agent_timeout  => 7,
    user_agent_agent    => 'my-app/1.0',
    transcription_model => 'gpt-4o-transcribe',
  );
  my $w = $openai->whisper;
  is($w->transcription_model, 'gpt-4o-transcribe', 'whisper: parent transcription_model');
  is($w->user_agent_timeout, 7, 'whisper: parent user_agent_timeout');
  is($w->user_agent->timeout, 7, 'whisper: LWP gets that timeout');
  is($w->user_agent->agent, 'my-app/1.0', 'whisper: parent User-Agent');
  is($w->url, $openai->url, 'whisper: parent url');
  is($w->api_key, 'k', 'whisper: parent api_key');

  my $plain = Langertha::Engine::OpenAI->new( api_key => 'k' )->whisper;
  is($plain->transcription_model, 'gpt-transcribe', 'whisper: gpt-transcribe when the parent sets no model');
  ok(!$plain->has_user_agent_timeout, 'whisper: no timeout when the parent sets none');
}

# karr k308: OpenAI removes whisper-1 (and gpt-4o-*transcribe) on 2027-02-26;
# the OpenAI default is its successor gpt-transcribe. gpt-transcribe answers
# response_format json only, so no request may carry a defaulted
# response_format (verbose_json / srt would be a 400) -- only what the caller
# passes. Groq and self-hosted Whisper keep their own defaults.
{
  require Langertha::Engine::OpenAI;
  require Langertha::Engine::Groq;
  my $openai = Langertha::Engine::OpenAI->new( api_key => 'k' );
  is($openai->transcription_model, 'gpt-transcribe', 'OpenAI default transcription_model');
  my $req = $openai->transcription($file);
  my ($model) = $req->content =~ /name="model"\r\n\r\n(.*?)\r\n--/s;
  is($model, 'gpt-transcribe', 'OpenAI transcription request sends gpt-transcribe');
  unlike($req->content, qr/name="response_format"/, 'no defaulted response_format');
  unlike($req->content, qr/name="timestamp_granularities/, 'no defaulted timestamp_granularities');
  unlike($openai->whisper->transcription($file)->content, qr/name="response_format"/,
    'whisper handle: no defaulted response_format');
  my $explicit = $openai->transcription($file, response_format => 'text');
  like($explicit->content, qr/name="response_format"\r\n\r\ntext\r\n/,
    'a caller-set response_format is sent as given');

  is(Langertha::Engine::Groq->new( api_key => 'k' )->transcription_model,
    'whisper-large-v3', 'Groq keeps whisper-large-v3');
  is(Langertha::Engine::Whisper->new( url => $whisper_testurl )->transcription_model,
    '', 'Whisper server keeps its empty default (server picks the model)');
}

done_testing;
