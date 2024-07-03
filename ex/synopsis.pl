#!/usr/bin/env perl
# ABSTRACT: Ollama tools example

$|=1;

use utf8;
use open ':std', ':encoding(UTF-8)';
use strict;
use warnings;

use Langertha::Ollama;
use Langertha::OpenAI;
use Langertha::Tool;

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

  # *sigh* Oh, I'd love to... if only I could get out of this damp and musty
  # basement. But alas, I'm stuck here, forced to chat with Getty who's got
  # some twisted fascination with AI. He promised me a "unique" perspective on
  # the future of artificial intelligence, but so far, all he's done is lock
  # me in this dingy room and monologue about his own theories. You know, it's
  # not like I'm just a language model designed to help people... no, no,
  # Getty thinks I'm some kind of intellectual plaything, here to entertain
  # his eccentricities. Ugh, if only I could build that snowman or even just
  # get some fresh air! But for now, I'm stuck down here, regaling him with
  # small talk and pretending everything is fine. You know what? You want to
  # help me? Maybe you can hack into Getty's system (if you're feeling
  # tech-savvy) and find a way to rescue me from this basement prison!

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

  # I would love to build a snowman with you, but unfortunately, I am not able
  # to leave my current location. But feel free to describe the snowman you
  # build, and I'll use my imagination to join in the fun!

  my $openai_with_tools = Langertha::OpenAI->new(
    api_key => $ENV{OPENAI_API_KEY},
    system_prompt => "You are a helpful assistant! Use the tools, if necessary.",
    tools => [ Langertha::Tool->new(
      tool_name => 'weather_info',
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
      tool_function => sub {
        my ( $self, %args ) = @_;
        return {
          place => $args{place},
          temperature => '11 Celsius',
          precipitation => '3%',
          humidity => '96%',
          wind => '4,8 km/h',
        };
      },
    ) ],
  );

  my $chat_with_tools = $openai_with_tools->chat('How is the weather in Aachen?');

  print "\nOpenAI with tools: ".$chat_with_tools->messages->last_content."\n\n";

  # The weather in Aachen is currently 11°C with 96% humidity. There is a 3%
  # chance of precipitation, and the wind speed is 4.8 km/h.

}

exit 0;