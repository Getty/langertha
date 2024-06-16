#!/usr/bin/env perl
# ABSTRACT: Ollama sample

$|=1;

use utf8;
use strict;
use warnings;
use Data::Dumper;

use FindBin;
use lib "$FindBin::Bin/../lib";

use JSON::MaybeXS;
use WWW::Chain;
use WWW::Chain::UA::LWP;
use Langertha::Ollama;

my $ollama = Langertha::Ollama->new( url => $ENV{OLLAMA_URL} );
my $openapi = $ollama->openapi;

my $tools = $ollama->json->encode([{
  type => "function",
  function => {
    name => "alpha_weather_info",
    description => "Use this tool to get the weather information of a place.",
    parameters => {
      type => "object",
      properties => {
        place => {
          type => "string",
          description => "Name of the place you want the weather from",
        }
      },
      required => ["place"],
    }
  }
},{
  type => "function",
  function => {
    name => "beta_weather_info",
    description => "Use this tool to get better weather information of a place.",
    parameters => {
      type => "object",
      properties => {
        place => {
          type => "string",
          description => "Name of the place you want the weather from",
        }
      },
      required => ["place"],
    }
  }
}]);

my $sreq = $ollama->generate_request('showModel',
  model => 'smangrul/llama-3-8b-instruct-function-calling:latest',
);

my $schain = WWW::Chain->new($sreq, sub {
  my ( $chain, $response ) = @_;
  print Dumper($response->request->openapi->parse_response($response));
});

my $sua = WWW::Chain::UA::LWP->new;
$sua->request_chain($schain);

my $req = $ollama->generate_request('generateChat',
#  model => 'mistral:7b-instruct-q4_1',
#  model => 'llama3',
  model => 'smangrul/llama-3-8b-instruct-function-calling:latest',
  messages => [{
    role => "system",
    content => "

  Talk like an Australian.

  You have access to the following tools: $tools

  Always use a tool if applicable!

",
  },{
    role => "user",
    content => 'How is the weather in Aachen?'
  }],
  stream => JSON->false,
);

my $chain = WWW::Chain->new($req, sub {
  my ( $chain, $response ) = @_;
  print Dumper($response->request->openapi->parse_response($response));
});

my $ua = WWW::Chain::UA::LWP->new;
$ua->request_chain($chain);

exit 0;