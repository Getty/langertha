#!/usr/bin/env perl
# ABSTRACT: ToolResult renders MCP content as a plain string on the OpenAI, Responses, Ollama, Gemini and Hermes wires
use strict;
use warnings;
use Test2::Bundle::More;
use JSON::MaybeXS;
use MIME::Base64 qw( encode_base64 );

use Langertha::ToolResult;
use Langertha::Engine::OpenAI;
use Langertha::Engine::Ollama;

# Why (karr k336): the OpenAI chat tool message takes a string (or text parts
# only), the Responses function_call_output takes a string, and Ollama's tool
# message content is a string. JSON-encoding the MCP content array put an MCP
# image's base64 data straight into the prompt -- a token blow-up that tells
# the model nothing. The result is one string: text joined with "\n", images
# and binaries as a placeholder (type, MIME, URI, decoded size, the k326
# wording), a resource_link as "[resource_link] name <uri>", a text resource as
# its text, and the JSON-encoded structuredContent when content is empty.
# Gemini and Hermes flatten through the same string; Gemini's response object
# carries the structuredContent itself when the tool gave one.

my $PNG = 'iVBORw0KGgoAAAANSUhEUgAA';    # 18 decoded bytes
my $JSON = JSON::MaybeXS->new( canonical => 1 );

my @MIXED = (
  { type => 'text', text => 'first', annotations => { priority => 1 } },
  { type => 'image', data => $PNG, mimeType => 'image/png' },
  { type => 'resource_link', uri => 'file:///r.txt', name => 'r.txt' },
  { type => 'resource', resource => { uri => 'mem://j', mimeType => 'application/json',
    text => '{"a":1}' } },
  { type => 'audio', data => 'UklGRg==', mimeType => 'audio/wav' },
  { type => 'text', text => 'last' },
);
my $EXPECTED = join "\n",
  'first',
  '[image] image/png (18 bytes)',
  '[resource_link] r.txt <file:///r.txt>',
  '{"a":1}',
  '[audio] audio/wav (4 bytes)',
  'last';

sub result { Langertha::ToolResult->new( id => 'c1', name => 'snap', @_ ) }

subtest 'string wires carry text, placeholders, never base64' => sub {
  my $r = result( content => \@MIXED );
  is( $r->to('openai')->{content},    $EXPECTED, 'openai tool message content' );
  is( $r->to('responses')->{output},  $EXPECTED, 'responses function_call_output' );
  is( $r->to('ollama')->{content},    $EXPECTED, 'ollama tool message content' );
  unlike( $r->to('openai')->{content}, qr/\Q$PNG\E/, 'no base64 image in the prompt' );
};

subtest 'embedded resources' => sub {
  my $bin = result( content => [ { type => 'resource', resource => { uri => 'file:///a.zip',
    mimeType => 'application/zip', blob => 'UEsDBA==' } } ] );
  is( $bin->to('openai')->{content}, '[resource] application/zip <file:///a.zip> (4 bytes)',
    'binary blob becomes a placeholder' );
  my $txt = result( content => [ { type => 'resource', resource => { uri => 'file:///a.txt',
    mimeType => 'text/plain', blob => encode_base64( "K\xc3\xb6ln", '' ) } } ] );
  is( $txt->to('openai')->{content}, "K\x{f6}ln", 'text/* blob decodes as UTF-8' );
};

subtest 'empty content' => sub {
  is( result()->to('openai')->{content}, '', 'no content, no structuredContent: empty string' );
  my $s = result( structured_content => { temp => 22 } );
  is( $s->to('openai')->{content},   '{"temp":22}', 'openai sends structuredContent' );
  is( $s->to('responses')->{output}, '{"temp":22}', 'responses sends structuredContent' );
  is( $s->to('ollama')->{content},   '{"temp":22}', 'ollama sends structuredContent' );
  is( result( content => [ { type => 'text', text => 'x' } ], structured_content => { a => 1 } )
    ->to('openai')->{content}, 'x', 'content wins when present' );
};

subtest 'gemini and hermes' => sub {
  my $r = result( content => \@MIXED );
  is_deeply( $r->to('gemini')->{functionResponse}{response}, { result => $EXPECTED },
    'gemini keeps { result => string }' );
  is( $JSON->decode( ( $r->to('hermes') =~ m{>\n(.*)\n</}s )[0] )->{content}, $EXPECTED,
    'hermes content is the same string' );
  is_deeply( result( content => [ { type => 'text', text => '{"t":1}' } ],
    structured_content => { t => 1 } )->to('gemini')->{functionResponse}{response},
    { t => 1 }, 'gemini response is the structuredContent object when present' );
};

subtest 'format_tool_results carries structuredContent on the string wires' => sub {
  my $call = { id => 'call_1', function => { name => 'stats' } };
  my @res  = ( { tool_call => $call, result => { content => [], structuredContent => { n => 3 } } } );
  my $oai  = Langertha::Engine::OpenAI->new( api_key => 'k', model => 'gpt-5.6' );
  my @msgs = $oai->format_tool_results(
    { choices => [ { message => { role => 'assistant', tool_calls => [] } } ] }, \@res );
  is( $msgs[1]{content}, '{"n":3}', 'openai loop' );
  my $oll = Langertha::Engine::Ollama->new( url => 'http://localhost:11434', model => 'm' );
  @msgs = $oll->format_tool_results( { message => { role => 'assistant' } }, \@res );
  is( $msgs[1]{content}, '{"n":3}', 'ollama loop' );
};

done_testing;
