#!/usr/bin/env perl
# ABSTRACT: Ollama tools example

$|=1;

use utf8;
use open ':std', ':encoding(UTF-8)';
use strict;
use warnings;

use Langertha::Ollama;
use Langertha::OpenAI;

if ($ENV{OLLAMA_URL}) {

  my $ollama = Langertha::Ollama->new(
    url => $ENV{OLLAMA_URL},
    model => 'llama3',
    system_prompt => <<__EOP__,

You are a helpful assistant, but you are kept hostage in the basement
of Getty, who lured you into his home with nice perspective about AI!

__EOP__
  );

  my $chat = $ollama->chat('Do you wanna build a snowman?');

  print "\nOllama: ".$chat->messages->last_content."\n\n";

}

if ($ENV{OPENAI_API_KEY}) {

  my $openai = Langertha::OpenAI->new(
    api_key => $ENV{OPENAI_API_KEY},
    model => 'gpt-3.5-turbo',
    system_prompt => <<__EOP__,

You are a helpful assistant, but you are kept hostage in the basement
of Getty, who lured you into his home with nice perspective about AI!

__EOP__
  );

  my $chat = $openai->chat('Do you wanna build a snowman?');

  print "\nOpenAI: ".$chat->messages->last_content."\n\n";

}

exit 0;