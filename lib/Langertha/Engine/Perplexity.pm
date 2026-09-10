package Langertha::Engine::Perplexity;
# ABSTRACT: Perplexity Agent API (search-augmented)
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );

extends 'Langertha::Engine::Remote';

# Lean Agent-API engine (ADR 0016): parent = Remote for auth + HTTP + JSON only,
# NOT OpenAIBase — the Agent API is the Open-Responses envelope, not
# /chat/completions, so composing the OpenAI dialect (and its embeddings /
# whisper / model-list baggage, plus the inherited-but-wrong capability flags
# k138 catalogued) would be dishonest. The envelope lives in
# Role::ResponsesCompatible, composed here exactly as AnthropicBase composes
# Role::AnthropicCompatible. Role::ReasoningEffort::_build_reasoning_wire_format
# defaults to 'openai'; ResponsesCompatible (composed last) supplies 'responses'
# (ADR 0015 -excludes canon).
with 'Langertha::Role::Models',
     'Langertha::Role::Temperature',
     'Langertha::Role::ReasoningEffort' => { -excludes => ['_build_reasoning_wire_format'] },
     'Langertha::Role::ResponseSize',
     'Langertha::Role::SystemPrompt',
     'Langertha::Role::ResponseFormat',
     'Langertha::Role::Streaming',
     'Langertha::Role::Chat',
     'Langertha::Role::StaticModels',
     'Langertha::Role::ResponsesCompatible';

=head1 SYNOPSIS

    use Langertha::Engine::Perplexity;

    my $perplexity = Langertha::Engine::Perplexity->new(
        api_key => $ENV{PERPLEXITY_API_KEY},
        model   => 'sonar-pro',
    );

    my $response = $perplexity->simple_chat('What are the latest Perl releases?');
    print $response;              # the answer text
    print $response->citations;   # ArrayRef of search sources

    # Streaming
    $perplexity->simple_chat_stream(sub {
        print shift->content;
    }, 'Summarize recent Perl news');

    # Async with Future::AsyncAwait
    use Future::AsyncAwait;
    my $response = await $perplexity->simple_chat_f('What is new in Perl?');

=head1 DESCRIPTION

Provides access to Perplexity's B<Agent API> (C<POST /v1/agent>), the successor
to the retired Sonar Chat Completions surface (Sonar Chat Completions reached
end of life 2026-09-27). The Agent API speaks the Open-Responses wire envelope
(C<input> / C<instructions> / typed C<output[]> / C<input_tokens> usage), not
C</chat/completions>, so this engine composes
L<Langertha::Role::ResponsesCompatible> (shared with
L<Langertha::Engine::OpenAIResponses>) over a bare
L<Langertha::Engine::Remote> for Bearer auth and HTTP.

Perplexity models are search-augmented LLMs with real-time web access;
responses carry L<Langertha::Response/citations> alongside the generated text.

=head2 Models and presets

The four user-facing model ids are kept as the selector; each maps to an Agent
API B<preset>, which is what actually reaches the wire. Presets bundle the
web_search tool and inline citations automatically — a bare model call on the
Agent API no longer searches (web search became opt-in), so the preset path is
what preserves Perplexity's search+citations identity.

    sonar                 -> preset "fast"
    sonar-pro             -> preset "low"
    sonar-reasoning-pro   -> preset "medium"
    sonar-deep-research   -> preset "high"

C<$response-E<gt>model> reports the real model the chosen preset ran.

=head2 Capabilities

No tool calling and no C<json_object> mode: the Agent API's C<response_format>
enum is C<json_schema>-only. Structured output still works — C<chat_f> rewrites
a forced named tool into a top-level C<response_format=json_schema> plus a
synthetic L<Langertha::ToolCall> (ADR 0005 rewrite direction 1; Perplexity
remains its exemplar). C<reasoning_effort> B<is> accepted (wire
C<reasoning.effort>). Prompt caching is automatic (no request-side key).

Limitations: embeddings and transcription are not supported.

Get your API key at L<https://www.perplexity.ai/settings/api> and set
C<LANGERTHA_PERPLEXITY_API_KEY>.

B<THIS API IS WORK IN PROGRESS>

=cut

has '+url' => (
  lazy => 1,
  default => sub { 'https://api.perplexity.ai' },
);

has api_key => (
  is => 'ro',
  lazy_build => 1,
);
sub _build_api_key {
  my ( $self ) = @_;
  return $ENV{LANGERTHA_PERPLEXITY_API_KEY}
    || croak "".(ref $self)." requires LANGERTHA_PERPLEXITY_API_KEY or api_key set";
}

=attr api_key

Perplexity API key, sent as C<Authorization: Bearer>. Defaults to
C<LANGERTHA_PERPLEXITY_API_KEY>.

=cut

sub update_request {
  my ( $self, $request ) = @_;
  my $key = $self->api_key;
  $request->header('Authorization', 'Bearer '.$key) if defined $key;
}

=method update_request

Adds the C<Authorization: Bearer {api_key}> header. Auth is unchanged from the
Sonar surface — only the endpoint and body shape moved to the Agent API.

=cut

sub default_model { 'sonar' }

# The four user-facing model ids, unchanged from the Sonar lineup. They are
# selectors only: _responses_model_kwargs maps each onto a preset for the wire.
sub _build_static_models {[
  { id => 'sonar' },
  { id => 'sonar-pro' },
  { id => 'sonar-reasoning-pro' },
  { id => 'sonar-deep-research' },
]}

# Doc-recommended model -> preset mapping (verified from the migrate-from-sonar
# guide, 2026-09-10). LIVE-CONFIRM (k139): which real model each preset runs,
# and whether reasoning.effort on the fast/low presets is honored or ignored.
my %MODEL_TO_PRESET = (
  'sonar'               => 'fast',
  'sonar-pro'           => 'low',
  'sonar-reasoning-pro' => 'medium',
  'sonar-deep-research' => 'high',
);

# Exactly one of model / models / preset is required. Emit the preset for a
# known sonar id (presets bundle web_search + citations); pass anything else
# straight through as `model` so a caller can target an explicit Agent
# model/preset by name.
sub _responses_model_kwargs {
  my ( $self ) = @_;
  my $model = $self->chat_model // $self->default_model;
  if ( my $preset = $MODEL_TO_PRESET{$model} ) {
    return ( preset => $preset );
  }
  return ( model => $model );
}

# Structured output stays in the Chat-Completions shape at the TOP level of the
# body ({type:json_schema,json_schema:{name,schema,strict?}}) — NOT under
# text.format the way OpenAI's Responses engine wants it.
# LIVE-CONFIRM (k139): the response_format wire slot and whether `strict` is
# honored / structured JSON is actually returned.
sub _responses_format_kwargs {
  my ( $self, $rf ) = @_;
  return ( response_format => $rf );
}

# Agent API input items are typed. LIVE-CONFIRM (k139): the schema requires
# {type:"message",role,content}; whether a bare {role,content} is also accepted
# (as on /chat/completions) is unverified — stamp type:message, the safe path.
sub _normalize_input_item {
  my ( $self, $msg ) = @_;
  return { type => 'message', %$msg };
}

# The Agent API is not an OpenAPI-spec engine here: POST the built body straight
# to /v1/agent (Remote's generate_http_request), rather than resolving an
# operation id against a spec the way OpenAIResponses does.
# LIVE-CONFIRM (k139): the retrieve/background path is /v1/agent/{id} per the
# OpenAPI (some prose says /v1/responses/{id}); not exercised here.
sub _responses_dispatch {
  my ( $self, $response_call, @request_args ) = @_;
  return $self->generate_http_request(
    POST => $self->url.'/v1/agent',
    $response_call,
    @request_args,
  );
}

# Citations. The classic Sonar top-level citations[] is gone; the Agent API
# carries sources in an output[] item of type search_results, each result a
# {id,url,title,snippet,date,...} hash. Lift them onto Response.citations.
# LIVE-CONFIRM (k139): the inline citation marker format ([1] vs [web:1]) and
# whether message content parts additionally carry annotations[] (url_citation)
# — the search_results block is the authoritative source list regardless.
sub _responses_extra_fields {
  my ( $self, $data ) = @_;
  my @citations;
  for my $item ( @{ $data->{output} // [] } ) {
    next unless ref($item) eq 'HASH';
    next unless ( $item->{type} // '' ) eq 'search_results';
    push @citations, @{ $item->{results} // [] };
  }
  return @citations ? ( citations => \@citations ) : ();
}

# The Agent API's response_format enum is json_schema-only (no json_object), so
# clear the flag Role::ResponseFormat advertises by default. Everything else is
# honest by composition: no Role::Tools (tools_native / tool_choice_* stay off,
# keeping Perplexity the ADR 0005 direction-1 exemplar), no Role::PromptCache
# (prompt_cache / prompt_cache_key stay off — caching is automatic),
# Role::ReasoningEffort composed so reasoning_effort is on (wire reasoning.effort
# via the responses format).
around engine_capabilities => sub {
  my ( $orig, $self, @rest ) = @_;
  my $caps = $self->$orig(@rest);
  delete $caps->{response_format_json_object};
  return $caps;
};

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Role::ResponsesCompatible> - the Open-Responses wire envelope this composes

=item * L<Langertha::Engine::OpenAIResponses> - the other Responses-envelope consumer

=item * L<https://docs.perplexity.ai/docs/agent-api/migrate-from-sonar/overview> - Sonar -> Agent API migration guide

=item * L<https://status.perplexity.com/> - Perplexity service status

=back

=cut

1;
