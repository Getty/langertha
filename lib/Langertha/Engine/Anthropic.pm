package Langertha::Engine::Anthropic;
# ABSTRACT: Anthropic API
our $VERSION = '0.101';
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
  Streaming
));

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

# New parameters (February 2026)
has effort => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_effort',
);

has inference_geo => (
  is => 'ro',
  isa => 'Str',
  predicate => 'has_inference_geo',
);

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

sub default_model { 'claude-sonnet-4-6' }

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
    $self->has_effort ? ( effort => $self->effort ) : (),
    $self->has_inference_geo ? ( inference_geo => $self->inference_geo ) : (),
    $system ? ( system => $system ) : (),
    %extra,
  );
}

sub chat_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);
  my @messages = @{$data->{content}};
  require Langertha::Response;
  return Langertha::Response->new(
    content       => $messages[0]->{text} // '',
    raw           => $data,
    $data->{id} ? ( id => $data->{id} ) : (),
    $data->{model} ? ( model => $data->{model} ) : (),
    defined $data->{stop_reason} ? ( finish_reason => $data->{stop_reason} ) : (),
    $data->{usage} ? ( usage => $data->{usage} ) : (),
  );
}

sub stream_format { 'sse' }

sub chat_stream_request {
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
  return $self->generate_http_request( POST => $self->url.'/v1/messages', sub {},
    model => $self->chat_model,
    messages => \@msgs,
    max_tokens => $self->get_response_size,
    $self->has_temperature ? ( temperature => $self->temperature ) : (),
    $self->has_effort ? ( effort => $self->effort ) : (),
    $self->has_inference_geo ? ( inference_geo => $self->inference_geo ) : (),
    $system ? ( system => $system ) : (),
    stream => JSON->true,
    %extra,
  );
}

sub parse_stream_chunk {
  my ( $self, $data, $event ) = @_;

  require Langertha::Stream::Chunk;

  # Anthropic uses event types: content_block_delta, message_delta, message_stop
  my $type = $data->{type} // '';

  if ($type eq 'content_block_delta') {
    my $delta = $data->{delta} || {};
    return Langertha::Stream::Chunk->new(
      content => $delta->{text} // '',
      raw => $data,
      is_final => 0,
    );
  }

  if ($type eq 'message_delta') {
    my $delta = $data->{delta} || {};
    return Langertha::Stream::Chunk->new(
      content => '',
      raw => $data,
      is_final => 0,
      $delta->{stop_reason} ? (finish_reason => $delta->{stop_reason}) : (),
      $data->{usage} ? (usage => $data->{usage}) : (),
    );
  }

  if ($type eq 'message_stop') {
    return Langertha::Stream::Chunk->new(
      content => '',
      raw => $data,
      is_final => 1,
    );
  }

  # Other event types (message_start, content_block_start, etc.) - skip
  return undef;
}

# Dynamic model listing with cursor pagination
sub list_models_request {
  my ($self, %params) = @_;
  my $url = $self->url.'/v1/models';

  # Add pagination params if provided
  if (%params) {
    require URI;
    my $uri = URI->new($url);
    $uri->query_form(%params);
    $url = $uri->as_string;
  }

  return $self->generate_http_request(
    GET => $url,
    sub { $self->list_models_response(shift) },
  );
}

sub list_models_response {
  my ($self, $response) = @_;
  my $data = $self->parse_response($response);
  return $data;
}

sub _fetch_all_models {
  my ($self) = @_;
  my @all_models;
  my $after_id;

  do {
    my $request = $self->list_models_request(
      $after_id ? (after_id => $after_id, limit => 100) : ()
    );
    my $response = $self->user_agent->request($request);
    my $data = $request->response_call->($response);

    push @all_models, @{$data->{data}};
    $after_id = $data->{has_more} ? $data->{last_id} : undef;
  } while ($after_id);

  return \@all_models;
}

sub list_models {
  my ($self, %opts) = @_;

  # Check cache unless force_refresh requested
  unless ($opts{force_refresh}) {
    my $cache = $self->_models_cache;
    if ($cache->{timestamp} && time - $cache->{timestamp} < $self->models_cache_ttl) {
      return $opts{full} ? $cache->{models} : $cache->{model_ids};
    }
  }

  # Fetch all pages from API
  my $models = $self->_fetch_all_models;

  # Extract IDs and update cache
  my @model_ids = map { $_->{id} } @$models;
  $self->_models_cache({
    timestamp => time,
    models => $models,
    model_ids => \@model_ids,
  });

  return $opts{full} ? $models : \@model_ids;
}

# Tool calling support (MCP)

sub format_tools {
  my ( $self, $mcp_tools ) = @_;
  return [map {
    {
      name         => $_->{name},
      description  => $_->{description},
      input_schema => $_->{inputSchema},
    }
  } @$mcp_tools];
}

sub response_tool_calls {
  my ( $self, $data ) = @_;
  return [grep { $_->{type} eq 'tool_use' } @{$data->{content} // []}];
}

sub extract_tool_call {
  my ( $self, $tc ) = @_;
  return ( $tc->{name}, $tc->{input} );
}

sub response_text_content {
  my ( $self, $data ) = @_;
  return join('', map { $_->{text} }
    grep { $_->{type} eq 'text' } @{$data->{content} // []})
}

sub format_tool_results {
  my ( $self, $data, $results ) = @_;
  return (
    { role => 'assistant', content => $data->{content} },
    { role => 'user', content => [
      map {
        my $r = $_;
        {
          type        => 'tool_result',
          tool_use_id => $r->{tool_call}{id},
          content     => $r->{result}{content},
          $r->{result}{isError} ? ( is_error => JSON->true ) : (),
        }
      } @$results
    ]},
  );
}

with 'Langertha::Role::Tools';

__PACKAGE__->meta->make_immutable;

=head1 SYNOPSIS

  use Langertha::Engine::Anthropic;

  # Basic usage
  my $claude = Langertha::Engine::Anthropic->new(
    api_key => $ENV{ANTHROPIC_API_KEY},
    model => 'claude-sonnet-4-6',
    response_size => 4096,
    temperature => 0.7,
  );

  # Simple chat
  my $response = $claude->simple_chat('Generate Perl Moose classes to represent GeoJSON data types');
  print $response;

  # Streaming
  $claude->simple_chat_stream(sub {
    my ($chunk) = @_;
    print $chunk->content;
  }, 'Tell me about Perl');

  # Async with Future::AsyncAwait
  use Future::AsyncAwait;

  async sub ask_claude {
    my $response = await $claude->simple_chat_f('What is the meaning of life?');
    say $response;
  }

=head1 DESCRIPTION

This module provides access to Anthropic's Claude models via their API.
Claude is a family of large language models known for their helpfulness,
harmlessness, and honesty.

B<Available Models (February 2026):>

=over 4

=item * B<claude-opus-4-6> - Most capable model with 1M token context, strongest coding, planning, and debugging capabilities. Released February 5, 2026. Best for complex tasks, code review, and agentic workflows.

=item * B<claude-sonnet-4-6> - Balanced performance and speed (default). Released November 24, 2025. Excellent for most general-purpose tasks.

=item * B<claude-haiku-4-5-20251001> - Fastest and most cost-efficient model. Matches Sonnet 4's performance on coding, computer use, and agent tasks while being significantly cheaper.

=back

The Claude model family is organized by capability: Haiku (fastest/cheapest), Sonnet (balanced), and Opus (most capable/expensive).

B<Features:>

=over 4

=item * Streaming support (SSE-based)

=item * System prompts

=item * Temperature control

=item * Response size limits (max_tokens)

=item * Async/await support via Future::AsyncAwait

=item * Dynamic model discovery via API

=item * Advanced parameters: effort (thinking depth), inference_geo (data residency)

=back

B<THIS API IS WORK IN PROGRESS>

=head1 NEW PARAMETERS (FEBRUARY 2026)

Anthropic has introduced new parameters for enhanced control:

=head2 effort

Controls the depth of thinking for reasoning models. Values: C<low>, C<medium>, C<high>.

  my $claude = Langertha::Engine::Anthropic->new(
    api_key => $ENV{ANTHROPIC_API_KEY},
    model => 'claude-opus-4-6',
    effort => 'high',  # More thorough reasoning
  );

=head2 inference_geo

Controls data residency for inference. Values: C<us>, C<eu>.

  my $claude = Langertha::Engine::Anthropic->new(
    api_key => $ENV{ANTHROPIC_API_KEY},
    model => 'claude-sonnet-4-6',
    inference_geo => 'eu',  # Process in EU region
  );

=head1 LISTING AVAILABLE MODELS

Dynamically fetch available models from the Anthropic API (with cursor pagination):

  # Get simple list of model IDs
  my $model_ids = $engine->list_models;
  # Returns: ['claude-opus-4-6', 'claude-sonnet-4-6', ...]

  # Get full model objects with metadata
  my $models = $engine->list_models(full => 1);
  # Returns: [{id => '...', display_name => '...', created_at => '...'}, ...]

  # Force refresh (bypass cache)
  my $models = $engine->list_models(force_refresh => 1);

B<Caching:> Results are cached for 1 hour by default. Configure the TTL:

  my $engine = Langertha::Engine::Anthropic->new(
    api_key => $ENV{ANTHROPIC_API_KEY},
    models_cache_ttl => 1800, # 30 minutes
  );

  # Clear the cache manually
  $engine->clear_models_cache;

=head1 GETTING AN API KEY

Sign up at L<https://console.anthropic.com/> and generate an API key.

Set the environment variable:

  export ANTHROPIC_API_KEY=your-key-here
  # Or use LANGERTHA_ANTHROPIC_API_KEY

=head1 SEE ALSO

=over 4

=item * L<https://docs.anthropic.com/> - Official Anthropic documentation

=item * L<Langertha::Role::Chat> - Chat interface methods

=item * L<Langertha> - Main Langertha documentation

=back

=cut
