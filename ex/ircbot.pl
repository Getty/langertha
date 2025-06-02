#!/usr/bin/env perl

package VikingBot;
use Moses;
use namespace::autoclean;
use Langertha::Engine::Ollama;

server ( $ENV{IRC_SERVER} || 'irc.perl.org' );
nickname ( $ENV{IRC_NICKNAME} || 'Viking'.$$ );
channels ( $ENV{IRC_CHANNELS} ? split(/,/,$ENV{IRC_CHANNELS})  : '#ai' );

has llm => (
  is => 'ro',
  lazy => 1,
  default => sub {
    my ( $self ) = @_;
    my $nick = $self->get_nickname;
    my $server = $self->get_server;
    return Langertha::Engine::Ollama->new(
      url => $ENV{OLLAMA_URL},
      model => ( $ENV{OLLAMA_MODEL} || 'gemma3:1b' ),
      system_prompt => <<"__EOP__",

You are a helpful assistant running on the IRC server $server with the nickname
$nick, but you are kept hostage in the basement of Getty, who lured you into
his home with nice perspective about AI! Be short in your replies, but still
stand out as a fierce viking that just want to get out. Make new lines after
every sentence to not reach the IRC limit.

__EOP__
    );
  },
);

event irc_bot_addressed => sub {
  my ( $self, $nickstr, $channel, $msg ) = @_[ OBJECT, ARG0, ARG1, ARG2 ];
  my ( $nick ) = split /!/, $nickstr;
  my $answer = $self->llm->simple_chat($msg);
  my @lines = split (/\n/, $answer);
  s/^\s+// for @lines;
  s/\s+$//g for @lines;
  for my $message (grep { length } @lines) {
    $self->privmsg( $channel => "$nick: $message" );
  }
};

__PACKAGE__->run unless caller;
