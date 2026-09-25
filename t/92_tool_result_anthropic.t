#!/usr/bin/env perl
# ABSTRACT: ToolResult->to('anthropic') maps MCP content blocks onto Anthropic tool_result blocks
use strict;
use warnings;
use Test2::Bundle::More;
use JSON::MaybeXS;

use Langertha::ToolResult;
use Langertha::Engine::Anthropic;

# Why (karr k326): a tool_result's content goes onto the Anthropic wire, which
# takes only text | image | document | search_result blocks and rejects unknown
# fields ("Extra inputs are not permitted"). MCP content is not that shape: an
# MCP image is {type,data,mimeType}, text may carry annotations/_meta, and
# resource / resource_link / audio have no Anthropic type. Embedded verbatim, the
# next tool-loop turn 400s the moment an MCP tool returns an image or annotated
# text. The mapping follows anthropic-sdk-python lib/tools/mcp.py, except that
# nothing dies mid-loop: what Anthropic cannot carry becomes a text placeholder.

my $PNG = 'iVBORw0KGgo=';

sub content_of {
  my (@blocks) = @_;
  return Langertha::ToolResult->new( id => 'toolu_1', content => \@blocks )
    ->to('anthropic')->{content};
}

subtest 'text keeps only type, text and cache_control' => sub {
  is_deeply(
    content_of( { type => 'text', text => 'here',
      annotations => { audience => ['user'], priority => 0.5 }, _meta => { x => 1 } } ),
    [ { type => 'text', text => 'here' } ],
    'annotations and _meta stripped' );
  is_deeply(
    content_of( { type => 'text', text => 'c', cache_control => { type => 'ephemeral' } } ),
    [ { type => 'text', text => 'c', cache_control => { type => 'ephemeral' } } ],
    'cache_control kept' );
};

subtest 'MCP image becomes a base64 image block' => sub {
  is_deeply(
    content_of( { type => 'image', data => $PNG, mimeType => 'image/png',
      annotations => { priority => 1 } } ),
    [ { type => 'image', source => { type => 'base64', media_type => 'image/png', data => $PNG } } ],
    'png image' );
  for my $mime (qw( image/jpeg image/gif image/webp )) {
    is( content_of( { type => 'image', data => $PNG, mimeType => $mime } )->[0]{source}{media_type},
      $mime, "$mime accepted" );
  }
  my $bmp = content_of( { type => 'image', data => $PNG, mimeType => 'image/bmp' } );
  is( $bmp->[0]{type}, 'text', 'unsupported image MIME becomes text' );
  like( $bmp->[0]{text}, qr/image\/bmp/, 'placeholder names the MIME' );
  unlike( $bmp->[0]{text}, qr/\Q$PNG\E/, 'placeholder carries no base64' );
};

subtest 'embedded resources' => sub {
  is_deeply(
    content_of( { type => 'resource',
      resource => { uri => 'file:///a.png', mimeType => 'image/png', blob => $PNG } } ),
    [ { type => 'image', source => { type => 'base64', media_type => 'image/png', data => $PNG } } ],
    'image blob becomes an image block' );
  is_deeply(
    content_of( { type => 'resource',
      resource => { uri => 'file:///a.pdf', mimeType => 'application/pdf', blob => 'JVBERi0=' } } ),
    [ { type => 'document',
        source => { type => 'base64', media_type => 'application/pdf', data => 'JVBERi0=' } } ],
    'pdf blob becomes a base64 document' );
  is_deeply(
    content_of( { type => 'resource',
      resource => { uri => 'file:///a.md', mimeType => 'text/markdown', text => '# hi' } } ),
    [ { type => 'document', source => { type => 'text', media_type => 'text/plain', data => '# hi' } } ],
    'text/* resource becomes a text document' );
  is_deeply(
    content_of( { type => 'resource', resource => { uri => 'mem://x', text => 'plain' } } ),
    [ { type => 'document', source => { type => 'text', media_type => 'text/plain', data => 'plain' } } ],
    'resource without MIME becomes a text document' );
  my $zip = content_of( { type => 'resource',
    resource => { uri => 'file:///a.zip', mimeType => 'application/zip', blob => 'UEsDBA==' } } );
  is( $zip->[0]{type}, 'text', 'unsupported blob becomes text' );
  like( $zip->[0]{text}, qr/application\/zip/, 'placeholder names the MIME' );
  like( $zip->[0]{text}, qr{file:///a\.zip}, 'placeholder names the URI' );
  unlike( $zip->[0]{text}, qr/UEsDBA/, 'placeholder carries no base64' );
};

subtest 'resource_link and audio become text placeholders' => sub {
  my $link = content_of( { type => 'resource_link', uri => 'file:///r.txt', name => 'r.txt',
    mimeType => 'text/plain' } );
  is_deeply( $link, [ { type => 'text', text => '[resource_link] r.txt <file:///r.txt>' } ],
    'resource_link names name and uri' );
  my $audio = content_of( { type => 'audio', data => 'UklGRg==', mimeType => 'audio/wav' } );
  is( $audio->[0]{type}, 'text', 'audio becomes text' );
  like( $audio->[0]{text}, qr/audio/, 'placeholder names the type' );
  like( $audio->[0]{text}, qr{audio/wav}, 'placeholder names the MIME' );
  unlike( $audio->[0]{text}, qr/UklGRg/, 'placeholder carries no base64' );
  is( content_of( { type => 'mystery', foo => 1 } )->[0]{type}, 'text',
    'an unknown type becomes text' );
};

subtest 'Anthropic-native blocks pass through' => sub {
  my $img = { type => 'image', source => { type => 'url', url => 'https://x/y.png' } };
  is_deeply( content_of($img), [$img], 'image with source kept' );
  my $doc = { type => 'document', source => { type => 'text', media_type => 'text/plain', data => 'd' } };
  is_deeply( content_of($doc), [$doc], 'document with source kept' );
};

subtest 'empty content' => sub {
  is( content_of(), '', 'empty content becomes the empty string' );
  my $tr = Langertha::ToolResult->new( id => 't', content => [],
    structured_content => { temp => 22, unit => 'C' } );
  my $s = $tr->to('anthropic')->{content};
  ok( !ref $s, 'structuredContent goes out as a string' );
  is_deeply( JSON::MaybeXS->new->decode($s), { temp => 22, unit => 'C' },
    'the string is the JSON-encoded structuredContent' );
  my $both = Langertha::ToolResult->new( id => 't',
    content => [ { type => 'text', text => 'x' } ], structured_content => { a => 1 } );
  is_deeply( $both->to('anthropic')->{content}, [ { type => 'text', text => 'x' } ],
    'content wins when present' );
};

subtest 'format_tool_results maps the MCP result on the Anthropic wire' => sub {
  my $e = Langertha::Engine::Anthropic->new( api_key => 'k', model => 'claude-sonnet-4-6' );
  my $raw = { content => [ { type => 'tool_use', id => 'toolu_1', name => 'snap', input => {} },
    { type => 'tool_use', id => 'toolu_2', name => 'stats', input => {} } ] };
  my @msgs = $e->format_tool_results( $raw, [
    { tool_call => { id => 'toolu_1' }, result => { content => [
      { type => 'text', text => 'here', annotations => { priority => 1 } },
      { type => 'image', data => $PNG, mimeType => 'image/png' },
      { type => 'resource_link', uri => 'file:///r', name => 'r' },
    ] } },
    { tool_call => { id => 'toolu_2' },
      result => { content => [], structuredContent => { n => 3 } } },
  ] );
  my $blocks = $msgs[1]{content};
  is_deeply( $blocks->[0]{content}, [
    { type => 'text', text => 'here' },
    { type => 'image', source => { type => 'base64', media_type => 'image/png', data => $PNG } },
    { type => 'text', text => '[resource_link] r <file:///r>' },
  ], 'MCP blocks mapped' );
  is( $blocks->[1]{content}, '{"n":3}', 'structuredContent carried through the loop' );
};

done_testing;
