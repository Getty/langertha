#!/usr/bin/env perl
# ABSTRACT: OpenAI tools sample

$|=1;

use utf8;
use open ':std', ':encoding(UTF-8)';
use strict;
use warnings;
use Data::Dumper;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Langertha::OpenAI;
use Langertha::Tool;
use LWP::UserAgent;
use JSON::MaybeXS;

my $json = JSON::MaybeXS->new->utf8(1)->canonical(1)->pretty(1);
my $ua = LWP::UserAgent->new( timeout => 60 );

my $openai = Langertha::OpenAI->new(
  api_key => $ENV{OPENAI_API_KEY},
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
  ) ],
);

my $req = $openai->chat_request("What is the weather in Aachen and Mönchengladbach?");
my $req_body = $json->decode($req->decoded_content);
print Dumper($req_body);
 
my $res = $ua->request($req);
my $res_body = $json->decode($res->decoded_content);
print Dumper($res_body);

exit 0;