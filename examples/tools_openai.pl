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

my $ollama = Langertha::OpenAI->new( api_key => $ENV{OPENAI_API_KEY} );



exit 0;