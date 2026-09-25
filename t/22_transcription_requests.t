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

done_testing;
