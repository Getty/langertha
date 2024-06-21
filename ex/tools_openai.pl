#!/usr/bin/env perl
# ABSTRACT: OpenAI tools sample

$|=1;

use utf8;
use strict;
use warnings;
use Data::Dumper;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Langertha::OpenAI;
use Langertha::Tool;

my $openai = Langertha::OpenAI->new(
  api_key => $ENV{OPENAI_API_KEY},
  tools => [Langertha::Tool->new(
    tool_name => '',
    tool_description => '',
  ), Langertha::Tool->new(
    tool_name => '',
    tool_description => '',
  )],
);

exit 0;