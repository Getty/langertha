#!/usr/bin/env perl
# ABSTRACT: OpenAI sample

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
use Langertha::OpenAI;

my $ollama = Langertha::OpenAI->new( api_key => $ENV{OPENAI_API_KEY} );
my $openapi = $ollama->openapi;

my $req = $ollama->generate_request('createChatCompletion',
  model => 'gpt-3.5-turbo',
  messages => [{
    role => 'user',
    content => 'what is the weather in Aachen and Mönchengladbach?',
  }],
  tools => [{
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
  }],
);

my $chain = WWW::Chain->new($req, sub {
  my ( $chain, $response ) = @_;
  print Dumper($response->request->openapi->parse_response($response));
});

my $ua = WWW::Chain::UA::LWP->new;
$ua->request_chain($chain);

exit 0;