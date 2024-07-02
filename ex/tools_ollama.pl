#!/usr/bin/env perl
# ABSTRACT: Ollama tools example

$|=1;

use utf8;
use open ':std', ':encoding(UTF-8)';
use strict;
use warnings;
use Data::Dumper;
use Time::HiRes qw( time );

use FindBin;
use lib "$FindBin::Bin/../lib";

use Langertha::Ollama;
use Langertha::Tool;
use LWP::UserAgent;
use JSON::MaybeXS;

my $json = JSON::MaybeXS->new->utf8(1)->canonical(1)->pretty(1);
my $ua = LWP::UserAgent->new( timeout => 60 );

my @tools_models = qw(
  mistral:instruct
);
  # openhermes:latest
  # solar:10.7b
  # phi3:14b
  # phi3:latest
  # gemma2:9b
  # klcoder/mistral-7b-functioncall
  # nexusraven:latest
  # atlas/natural-functions:latest
  # dolphin-mixtral:latest
  # dolphincoder:latest
  # llama3:instruct
  # smangrul/llama-3-8b-instruct-function-calling:latest

my $system_prompt;
my $user_query = "What is the weather in Aachen and Mönchengladbach?";

my %results;

for my $model (@tools_models) {

  print STDERR "Querying $model... ";

  my $ollama = Langertha::Ollama->new(
    url => $ENV{OLLAMA_URL},
    model => $model,
    system_prompt => "You are a helpful assistant.",
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

  $system_prompt = $ollama->system_prompt unless defined $system_prompt;

  my $result = $ollama->chat($user_query);

  # my $req = $ollama->chat_request($user_query);
  # my $req_body = $json->decode($req->decoded_content);
  # print Dumper($req_body);

  # eval {

  #   my $start = time();
  #   my $res = $ua->request($req);
  #   my $end = time();
  #   $results{$model} = [$end - $start];
  #   my $res_body = $json->decode($res->decoded_content);

  #   if ($res_body->{message}->{content}) {
  #     push @{$results{$model}}, $res_body->{message}->{content};
  #   }

  #   print STDERR "done";

  # };
  # if ($@) { print STDERR $@."\n" }

  # print STDERR "\n";
}

print <<'__EOH__';
<!DOCTYPE html>
<html lang="en">
<head><meta http-equiv="Content-Type" content="text/html; charset=utf-8">
</head><body>
__EOH__
print "<table border='2'>\n";
print "<tr><th>System Prompt</th><td colspan='2'><pre>$system_prompt</pre></td></tr>";
print "<tr><th>User Query</th><td colspan='2'><pre>$user_query</pre></td></tr>";
print "<tr><td>$_</td><td>&nbsp;".sprintf("%.3f",($results{$_} and $results{$_}[0] ? $results{$_}[0] : 0))."&nbsp;</td><td>".($results{$_} and $results{$_}[1] ? $results{$_}[1] : "")."</td></tr>" for @tools_models;
print "</table>\n</body></html>";

exit 0;