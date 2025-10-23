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
  Temperature
  ResponseSize
  SystemPrompt
));

sub all_models {qw(
  claude-3-5-haiku-20241022
  claude-3-5-sonnet-20240620
  claude-3-5-sonnet-20241022
  claude-3-haiku-20240307
  claude-3-opus-20240229
  claude-3-sonnet-20240229
  claude-4
  claude-4-20250514
  claude-haiku-4
  claude-haiku-4-5
  claude-haiku-4-20250514
  claude-opus-4
  claude-opus-4-1-20250805
  claude-opus-4-20250514
  claude-sonnet-4-5
  claude-sonnet-4-20250514
)}

sub default_response_size { 1024 }

has api_key => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_ANTHROPIC_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_ANTHROPIC_API_KEY or api_key set";
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

sub default_model { 'claude-sonnet-4-5' }

sub chat_request {
  my ( $self, $messages, %extra ) = @_;
  my @msgs;
  my $system = "";
  for my $message (@{$messages}) {
    if ($message->{role} eq 'system') {
      $system .= "\n\n" if length $system;
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
    max_tokens => $self->get_response_size, # must be always set
    $self->has_temperature ? ( temperature => $self->temperature ) : (),
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

__PACKAGE__->meta->make_immutable;

=head1 SYNOPSIS

  use Langertha::Anthropic;

  my $claude = Langertha::Engine::Anthropic->new(
    api_key => $ENV{ANTHROPIC_API_KEY},
    model => 'claude-sonnet-4-5',
    response_size => 512,
    temperature => 0.5,
  );

  print($claude->simple_chat('Generate Perl Moose classes to represent GeoJSON data types'));

=head1 DESCRIPTION

B<THIS API IS WORK IN PROGRESS>

=head1 HOW TO GET ANTHROPIC API KEY

L<https://docs.anthropic.com/en/api/getting-started>

=cut
