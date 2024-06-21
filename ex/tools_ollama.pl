#!/usr/bin/env perl
# ABSTRACT: Ollama tools example

$|=1;

use utf8;
use strict;
use warnings;
use Data::Dumper;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Langertha::Ollama;
use Langertha::Tool;
use LWP::UserAgent;
 
my $ua  = LWP::UserAgent->new(
  protocols_allowed => ['http', 'https'],
  timeout => 10,
);

my $ollama = Langertha::Ollama->new(
  url => $ENV{OLLAMA_URL},
  model => 'klcoder/mistral-7b-functioncall',
  system_prompt => "You are a helpful assistant that speaks Australian!",
  tools => [ Langertha::Tool->new(
    tool_name => 'alpha_weather_info',
    tool_description => 'Use this tool to get the weather information of a place.',
    tool_parameters => {
      type => "object",
      properties => {
        place => {
          type => "string",
          description => "Name of the place you want the weather from",
        },
      },
      required => ["place"],
    },
  # ), Langertha::Tool->new(
  #   tool_name => 'beta_weather_info',
  #   tool_description => 'Use this tool to get better weather information of a place.',
  #   tool_parameters => {
  #     type => "object",
  #     properties => {
  #       place => {
  #         type => "string",
  #         description => "Name of the place you want the weather from",
  #       },
  #     },
  #     required => ["place"],
  #   },
  ) ],
);

my $req = $ollama->chat_request("What is the weather in Aachen and Mönchengladbach?");
 
my $response = $ua->request($req);

use DDP; p($response);

if ($response->is_success) {
  print $response->decoded_content;
}

exit 0;