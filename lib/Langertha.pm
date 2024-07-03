package Langertha;
# ABSTRACT: The clan of fierce vikings with axe and shield to AId your rAId

use strict;
use warnings;

1;

=head1 SYNOPSIS

Using L<https://ollama.com/>

  use Langertha::Ollama;

  my $ollama = Langertha::Ollama->new(
    url => 'http://127.0.0.1:11434',
    model => 'llama3',
    system_prompt => <<__EOP__,

  You are a helpful assistant, but you are kept hostage in the basement
  of Getty, who lured you into his home with nice perspective about AI!

  __EOP__
  );

  my $chat = $ollama->chat('Do you wanna build a snowman?');

  print $chat->messages->last_content;

Using L<https://platform.openai.com/>

  use Langertha::OpenAI;

  my $openai = Langertha::OpenAI->new(
    api_key => 'xx-proj-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
    model => 'gpt-3.5-turbo',
    system_prompt => <<__EOP__,

  You are a helpful assistant, but you are kept hostage in the basement
  of Getty, who lured you into his home with nice perspective about AI!

  __EOP__
  );

  my $chat = $openai->chat('Do you wanna build a snowman?');

  print $chat->messages->last_content;

=head1 DESCRIPTION

B<THIS API IS WORK IN PROGRESS>

=cut
