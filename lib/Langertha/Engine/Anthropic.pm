package Langertha::Engine::Anthropic;
# ABSTRACT: Anthropic API

use Moose;
use Carp qw( croak );
use JSON::MaybeXS;

with 'Langertha::Role::'.$_ for (qw(
  JSON
  HTTP
  Models
  Chat
  SystemPrompt
));

has max_tokens => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_max_tokens { 1024 }

has api_key => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_ANTHROPIC_API_KEY}
    || $ENV{ANTHROPIC_API_KEY}
    || croak "".(ref $self)." requires ANTHROPIC_API_KEY";
}

has api_version => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_api_version { '2023-06-01' }

sub update_request {
  my ( $self, $request ) = @_;
  $request->header('x-api-key', $self->api_key);
  $request->header('content-type', 'application/json');
  $request->header('anthropic-version', $self->api_version);
}

has '+url' => (
  lazy => 1,
  default => sub { 'https://api.anthropic.com' },
);
sub has_url { 1 }

sub default_model { 'claude-3-5-sonnet-20240620' }

sub chat_request {
  my ( $self, $messages, %extra ) = @_;
  my @msgs;
  my $system = "";
  for my $message (@{$messages}) {
    if ($message->{role} eq 'system') {
      $system .= $message->{content};
    } else {
      push @msgs, $message;
    }
  }
  if ($system and scalar @msgs == 0) {
    push @msgs, {
      role => 'user',
      content => $system,
    };
    $system = undef;
  }
  return $self->generate_http_request( POST => $self->url.'/v1/messages', sub { $self->chat_response(shift) },
    model => $self->chat_model,
    messages => \@msgs,
    max_tokens => $self->max_tokens,
    $system ? ( system => $system ) : (),
    %extra,
  );
}

sub chat_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  # tracing
  my @messages = @{$data->{content}};
  return $messages[0]->{text};
}

1;

=head1 SYNOPSIS

  use Langertha::Anthropic;

  my $claude = Langertha::Engine::Anthropic->new(
    api_key => $ENV{ANTHROPIC_API_KEY},
    model => 'claude-3-5-sonnet-20240620',
    max_tokens => 2048,
  );

  print($claude->simple_chat('Generate Perl Moose classes to represent GeoJSON data types'));

=head1 DESCRIPTION

B<THIS API IS WORK IN PROGRESS>

=head1 HOW TO GET ANTHROPIC API KEY

L<https://docs.anthropic.com/en/api/getting-started>

=cut
