package Langertha;
# ABSTRACT: The clan of fierce vikings with 🪓 and 🛡️ to AId your rAId

use utf8;
use strict;
use warnings;

1;

=head1 SYNOPSIS

  my $system_prompt = <<__EOP__;

  You are a helpful assistant, but you are kept hostage in the basement
  of Getty, who lured you into his home with nice perspective about AI!

  __EOP__

Using L<https://ollama.com/>:

  use Langertha::Ollama;

  my $ollama = Langertha::Engine::Ollama->new(
    url => 'http://127.0.0.1:11434',
    model => 'llama3.1',
    system_prompt => $system_prompt,
  );

  print $ollama->simple_chat('Do you wanna build a snowman?');

Using L<https://platform.openai.com/>:

  use Langertha::OpenAI;

  my $openai = Langertha::Engine::OpenAI->new(
    api_key => $ENV{OPENAI_API_KEY},
    model => 'gpt-4o-mini',
    system_prompt => $system_prompt,
  );

  print $openai->simple_chat('Do you wanna build a snowman?');

Using L<https://console.anthropic.com/>:

  use Langertha::Anthropic;

  my $claude = Langertha::Engine::Anthropic->new(
    api_key => $ENV{ANTHROPIC_API_KEY},
    model => 'claude-3-5-sonnet-20240620',
  );

  print $claude->simple_chat('Generate Perl Moose classes to represent GeoJSON data.');

=head1 DESCRIPTION

B<THIS API IS WORK IN PROGRESS>

=head1 SUPPORT

Repository

  https://github.com/Getty/langertha
  Pull request and additional contributors are welcome
 
Issue Tracker

  https://github.com/Getty/langertha/issues

Discord

  https://discord.gg/Y2avVYpquV 🤖

IRC

  irc://irc.perl.org/ai 🤖

=cut