package Langertha::Engine::Gemini;
# ABSTRACT: Google Gemini API
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

sub default_response_size { 2048 }

has api_key => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_GEMINI_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_GEMINI_API_KEY or api_key set";
}

has '+url' => (
  lazy => 1,
  default => sub { 'https://generativelanguage.googleapis.com' },
);
sub has_url { 1 }

sub all_models {qw(
  gemini-2.0-flash
  gemini-1.5-pro
  gemini-1.5-flash
)}

sub default_model { 'gemini-2.0-flash' }

sub chat_request {
  my ( $self, $messages, %extra ) = @_;

  # Convert messages to Gemini format
  my @gemini_contents;
  my $system_instruction;

  for my $message (@{$messages}) {
    if ($message->{role} eq 'system') {
      # Gemini uses systemInstruction field for system messages
      $system_instruction .= "\n\n" if $system_instruction;
      $system_instruction .= $message->{content};
    } else {
      # Convert role: 'assistant' -> 'model' for Gemini
      my $role = $message->{role} eq 'assistant' ? 'model' : $message->{role};
      push @gemini_contents, {
        role => $role,
        parts => [{ text => $message->{content} }],
      };
    }
  }

  # Build the URL with model and API key
  my $model_name = $self->chat_model;
  my $url = $self->url . "/v1beta/models/${model_name}:generateContent?key=" . $self->api_key;

  my %request_body = (
    contents => \@gemini_contents,
  );

  # Add system instruction if present
  if ($system_instruction) {
    $request_body{systemInstruction} = {
      parts => [{ text => $system_instruction }],
    };
  }

  # Add generation config
  my %generation_config;
  if ($self->get_response_size) {
    $generation_config{maxOutputTokens} = $self->get_response_size;
  }
  if ($self->has_temperature) {
    $generation_config{temperature} = $self->temperature;
  }

  $request_body{generationConfig} = \%generation_config if %generation_config;

  return $self->generate_http_request(
    POST => $url,
    sub { $self->chat_response(shift) },
    %request_body,
    %extra,
  );
}

sub update_request {
  my ( $self, $request ) = @_;
  $request->header('content-type', 'application/json');
}

sub chat_response {
  my ( $self, $response ) = @_;
  my $data = $self->parse_response($response);

  # Gemini response format: candidates[0].content.parts[0].text
  my $candidates = $data->{candidates} || [];
  return '' unless @$candidates;

  my $candidate = $candidates->[0];
  my $content = $candidate->{content} || {};
  my $parts = $content->{parts} || [];

  return '' unless @$parts;
  return $parts->[0]->{text} || '';
}

sub stream_format { 'sse' }

sub chat_stream_request {
  my ( $self, $messages, %extra ) = @_;

  # Convert messages to Gemini format (same as non-streaming)
  my @gemini_contents;
  my $system_instruction;

  for my $message (@{$messages}) {
    if ($message->{role} eq 'system') {
      $system_instruction .= "\n\n" if $system_instruction;
      $system_instruction .= $message->{content};
    } else {
      my $role = $message->{role} eq 'assistant' ? 'model' : $message->{role};
      push @gemini_contents, {
        role => $role,
        parts => [{ text => $message->{content} }],
      };
    }
  }

  # Build the URL for streaming endpoint
  my $model_name = $self->chat_model;
  my $url = $self->url . "/v1beta/models/${model_name}:streamGenerateContent?key=" . $self->api_key . "&alt=sse";

  my %request_body = (
    contents => \@gemini_contents,
  );

  if ($system_instruction) {
    $request_body{systemInstruction} = {
      parts => [{ text => $system_instruction }],
    };
  }

  my %generation_config;
  if ($self->get_response_size) {
    $generation_config{maxOutputTokens} = $self->get_response_size;
  }
  if ($self->has_temperature) {
    $generation_config{temperature} = $self->temperature;
  }

  $request_body{generationConfig} = \%generation_config if %generation_config;

  return $self->generate_http_request(
    POST => $url,
    sub {},
    %request_body,
    %extra,
  );
}

sub parse_stream_chunk {
  my ( $self, $data, $event ) = @_;

  require Langertha::Stream::Chunk;

  # Gemini streaming format is similar to non-streaming
  my $candidates = $data->{candidates} || [];
  return undef unless @$candidates;

  my $candidate = $candidates->[0];
  my $content = $candidate->{content} || {};
  my $parts = $content->{parts} || [];

  my $text = '';
  $text = $parts->[0]->{text} if @$parts && $parts->[0]->{text};

  my $finish_reason = $candidate->{finishReason};
  my $is_final = defined $finish_reason && $finish_reason ne '';

  return Langertha::Stream::Chunk->new(
    content => $text,
    raw => $data,
    is_final => $is_final,
    $finish_reason ? (finish_reason => $finish_reason) : (),
    $data->{usageMetadata} ? (usage => $data->{usageMetadata}) : (),
  );
}

# Dynamic model listing with token pagination
sub list_models_request {
  my ($self, %params) = @_;
  my $url = $self->url . '/v1beta/models?key=' . $self->api_key;

  # Add pagination params if provided
  if (%params) {
    require URI;
    my $uri = URI->new($url);
    my %query = $uri->query_form;
    $uri->query_form(%query, %params);
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
  my $page_token;

  do {
    my $request = $self->list_models_request(
      $page_token ? (pageToken => $page_token) : ()
    );
    my $response = $self->user_agent->request($request);
    my $data = $request->response_call->($response);

    push @all_models, @{$data->{models} || []};
    $page_token = $data->{nextPageToken};
  } while ($page_token);

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
  # Gemini uses 'name' field like "models/gemini-2.0-flash"
  my @model_ids = map {
    my $name = $_->{name};
    $name =~ s{^models/}{};  # Strip "models/" prefix
    $name;
  } @$models;

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
  return [{
    functionDeclarations => [map {
      {
        name        => $_->{name},
        description => $_->{description},
        parameters  => $_->{inputSchema},
      }
    } @$mcp_tools],
  }];
}

sub response_tool_calls {
  my ( $self, $data ) = @_;
  my $candidates = $data->{candidates} || [];
  return [] unless @$candidates;
  my $parts = $candidates->[0]{content}{parts} || [];
  return [grep { exists $_->{functionCall} } @$parts];
}

sub response_text_content {
  my ( $self, $data ) = @_;
  my $candidates = $data->{candidates} || [];
  return '' unless @$candidates;
  my $parts = $candidates->[0]{content}{parts} || [];
  return join('', map { $_->{text} } grep { exists $_->{text} } @$parts);
}

sub format_tool_results {
  my ( $self, $data, $results ) = @_;
  my $candidate = $data->{candidates}[0];
  return (
    { role => 'model', parts => $candidate->{content}{parts} },
    { role => 'user', parts => [
      map {
        {
          functionResponse => {
            name     => $_->{tool_call}{functionCall}{name},
            response => $_->{result}{content},
          },
        }
      } @$results
    ]},
  );
}

with 'Langertha::Role::Tools';

__PACKAGE__->meta->make_immutable;

=head1 SYNOPSIS

  use Langertha::Engine::Gemini;

  # Basic usage
  my $gemini = Langertha::Engine::Gemini->new(
    api_key => $ENV{GEMINI_API_KEY},
    model => 'gemini-2.0-flash',
    response_size => 4096,
    temperature => 0.7,
  );

  # Simple chat
  my $response = $gemini->simple_chat('Explain quantum computing in simple terms');
  print $response;

  # Streaming
  $gemini->simple_chat_stream(sub {
    my ($chunk) = @_;
    print $chunk->content;
  }, 'Write a poem about Perl');

  # Async with Future::AsyncAwait
  use Future::AsyncAwait;

  async sub ask_gemini {
    my $response = await $gemini->simple_chat_f('What are the benefits of functional programming?');
    say $response;
  }

  async sub stream_gemini {
    my ($content, $chunks) = await $gemini->simple_chat_stream_realtime_f(
      sub { print shift->content },
      'Tell me about neural networks'
    );
    say "\nReceived ", scalar(@$chunks), " chunks";
  }

=head1 DESCRIPTION

This module provides access to Google's Gemini models via their Generative Language API.
Gemini is Google's family of multimodal AI models capable of understanding and generating
text, code, images, audio, and video.

B<Available Models:>

=over 4

=item * gemini-2.0-flash - Latest, fastest model with multimodal capabilities (default)

=item * gemini-1.5-pro - Most capable model, best for complex reasoning tasks

=item * gemini-1.5-flash - Fast and efficient model for high-volume tasks

=back

B<Features:>

=over 4

=item * Streaming support (SSE-based)

=item * System prompts (via systemInstruction)

=item * Temperature control (0.0 - 2.0)

=item * Response size limits (maxOutputTokens)

=item * Async/await support via Future::AsyncAwait

=item * Multimodal capabilities (text, code, images)

=item * Dynamic model discovery via API

=back

=head1 LISTING AVAILABLE MODELS

Dynamically fetch available models from the Gemini API (with token pagination):

  # Get simple list of model IDs
  my $model_ids = $engine->list_models;
  # Returns: ['gemini-2.0-flash-exp', 'gemini-1.5-pro', ...]

  # Get full model objects with metadata
  my $models = $engine->list_models(full => 1);

  # Force refresh (bypass cache)
  my $models = $engine->list_models(force_refresh => 1);

B<Note:> Model IDs have the "models/" prefix stripped for convenience.

B<Caching:> Results are cached for 1 hour. Configure TTL via C<models_cache_ttl>
or clear manually with C<clear_models_cache>.

B<Deprecation Notice:> The C<all_models()> method returns a hardcoded list.
Use C<list_models()> for current availability.

B<Key Capabilities:>

Gemini models support:

=over 4

=item * Long context windows (up to 2M tokens for Gemini 1.5 Pro)

=item * Multimodal understanding (text, images, video, audio)

=item * Function calling and tool use

=item * Code generation and understanding

=item * JSON mode for structured outputs

=back

B<THIS API IS WORK IN PROGRESS>

=head1 GETTING AN API KEY

Get your API key from L<https://aistudio.google.com/app/apikey>

You can use Gemini for free with rate limits, or upgrade to paid tiers for higher usage.

Set the environment variable:

  export GEMINI_API_KEY=your-key-here
  # Or use LANGERTHA_GEMINI_API_KEY

=head1 EXAMPLES

=head2 Basic Chat

  my $gemini = Langertha::Engine::Gemini->new(
    api_key => $ENV{GEMINI_API_KEY},
    model => 'gemini-2.0-flash',
  );

  my $answer = $gemini->simple_chat('What is the capital of France?');
  print $answer;

=head2 With System Prompt

  my $gemini = Langertha::Engine::Gemini->new(
    api_key => $ENV{GEMINI_API_KEY},
    model => 'gemini-1.5-pro',
    system_prompt => 'You are a helpful coding assistant specializing in Perl',
  );

  my $code = $gemini->simple_chat('Write a function to parse JSON');
  print $code;

=head2 Streaming Response

  $gemini->simple_chat_stream(sub {
    my ($chunk) = @_;
    print $chunk->content;
    STDOUT->flush;
  }, 'Write a short story about a robot learning to paint');

=head2 Async/Await Pattern

  use Future::AsyncAwait;

  async sub multi_question {
    my ($gemini) = @_;

    my $q1 = await $gemini->simple_chat_f('What is Perl?');
    say "Answer 1: $q1\n";

    my $q2 = await $gemini->simple_chat_f('What is Moose?');
    say "Answer 2: $q2\n";
  }

  multi_question($gemini)->get;

=head2 Controlled Generation

  my $gemini = Langertha::Engine::Gemini->new(
    api_key => $ENV{GEMINI_API_KEY},
    model => 'gemini-2.0-flash',
    temperature => 0.2,      # Lower = more deterministic
    response_size => 1024,   # Limit output tokens
  );

=head1 MODEL SELECTION

B<gemini-2.0-flash> (Default)

Latest and fastest model. Best for:
- General chat and conversation
- Quick responses
- High-volume applications
- Multimodal tasks

B<gemini-1.5-pro>

Most capable model. Best for:
- Complex reasoning and analysis
- Long-form content generation
- Tasks requiring deep understanding
- Maximum context window (2M tokens)

B<gemini-1.5-flash>

Fast and efficient. Best for:
- High-volume processing
- Real-time applications
- Cost-sensitive deployments
- Simple to moderate complexity tasks

=head1 SEE ALSO

=over 4

=item * L<https://ai.google.dev/gemini-api/docs> - Official Gemini API documentation

=item * L<https://aistudio.google.com/> - Google AI Studio for testing

=item * L<Langertha::Role::Chat> - Chat interface methods

=item * L<Langertha> - Main Langertha documentation

=back

=cut
