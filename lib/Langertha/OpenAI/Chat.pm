package Langertha::OpenAI::Chat;
# ABSTRACT: OpenAI Chat chain

use Moose;
extends 'WWW::Chain';

use Carp qw( croak );
use JSON::MaybeXS;
use Langertha::Message;

has openai => (
  isa => 'Langertha::OpenAI',
  is => 'ro',
  required => 1,
  handles => [qw(
    chat_request
    json
    tools_call
  )],
);

has messages => (
  isa => 'Langertha::Messages',
  is => 'ro',
  lazy_build => 1,
);
sub _build_messages {
  my ( $self ) = @_;
  return $self->openai->base_chat_messages($self->content);
}

has content => (
  isa => 'Str',
  is => 'ro',
  lazy_build => 1,
);
sub _build_content {
  my ( $self ) = @_;
  croak "".(ref $self)." requires content if no messages are given";
}

sub start_chain {
  my ( $self ) = @_;
  return $self->chat_request( $self->messages ), 'chat_response';
}

sub chat_response {
  my ( $self, $response ) = @_;
  my @response = $self->openai->chat_response($response);
  return @response if $self->is_request($response[0]);
  my $tools_messages;
  my @chat_messages;
  if ($response[0]->{choices}) {
    for my $choice (@{$response[0]->{choices}}) {
      if ($choice->{finish_reason} eq 'tool_calls') {
        $tools_messages = Langertha::Messages->new( messages => [] ) unless defined $tools_messages;
        $tools_messages->add_message(Langertha::Message->new({
          role => delete $choice->{message}->{role},
          content => delete $choice->{message}->{content},
          extra => $choice->{message},
        }));
        for my $call (@{$choice->{message}->{tool_calls}}) {
          my $function = $call->{function};
          my $id = $call->{id};
          if ($function and $id) {
            my $func = $function->{name};
            my $args = $self->json->decode($function->{arguments});
            $tools_messages->add_message(Langertha::Message->new({
              role => "tool",
              content => $self->json->encode($self->tools_call( $func => %{$args} )),
              extra => {
                tool_call_id => $id,
              },
            }));
          } else {
            $tools_messages->add_message(Langertha::Message->new({
              role => "tool",
              extra => {
                $id ? ( tool_call_id => $id ) : (),
              },
              content => undef,
            }));
          }
        }
      } else {
        push @chat_messages, Langertha::Message->new($choice->{message});
      }
    }
  }
  if (scalar @chat_messages > 0) {
    croak "".(ref $self)." can't have chat reply and tool call at once" if $tools_messages;
    $self->messages->add_message($_) for reverse @chat_messages;
  } elsif ($tools_messages) {
    return $self->chat_request( $tools_messages ), 'chat_response';
  } else {
    croak "".(ref $self)." has no meaningful reply of OpenAI";
  }
  return;
}

1;