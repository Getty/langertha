#!/usr/bin/env perl

$|=1;

use utf8;
use strict;
use warnings;
use Data::Dumper;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Langertha::Ollama;

my $ollama = Langertha::Ollama->new( url => $ENV{OLLAMA_URL} );
my $openapi = $ollama->openapi;

my $req = $ollama->generate_request('generateResponse',
  model => 'llama3',
  prompt => 'how are you?',
);

print Dumper($req);

exit 0;