#!/usr/bin/env perl
# ABSTRACT: probe_model_capabilities_f learns image_input from the provider's own model metadata (k270)

use strict;
use warnings;

use Test2::Bundle::More;
use lib 't/lib';

use JSON::MaybeXS;
use Path::Tiny qw( path );
use HTTP::Response;
use LWP::UserAgent;
use Test::LocalHTTPDaemon;
use Langertha::Request::SyncHTTP;
use Langertha::Manifest::Builder;
use Langertha::ModelProbe;
use Langertha::Engine::OpenRouter;
use Langertha::Engine::Mistral;
use Langertha::Engine::Ollama;
use Langertha::Engine::OllamaOpenAI;
use Langertha::Engine::LMStudio;
use Langertha::Engine::LMStudioOpenAI;
use Langertha::Engine::LlamaCpp;
use Langertha::Engine::OpenAI;
use Langertha::Engine::Anthropic;
use Langertha::Engine::TSystems;
use Langertha::Engine::AKI;

# karr k270 (ADR 0032): gateways and self-hosted servers make no static
# image_input claim, because the model behind them is unknown to the client
# (ADR 0019 k266 Update). Their own metadata does know: OpenRouter's
# architecture.input_modalities, Mistral's capabilities.vision, LM Studio's
# capabilities.vision, Ollama's /api/show capabilities, llama.cpp's /props
# modalities.vision. An explicit, opt-in probe stores those facts per engine
# instance; engine_capabilities applies them after the static per-model table,
# and the provider's statement wins for the models it describes -- in both
# directions. Nothing probes implicitly: supports() must never do network I/O,
# and without a probe every answer is the static one. The fixtures are shaped
# from each provider's documented response (no live calls, no captures exist).

delete @ENV{ grep { /\ALANGERTHA_/ } keys %ENV };

my $json = JSON::MaybeXS->new( canonical => 1, utf8 => 1 );
sub fixture { path( 't/data', $_[0] )->slurp_raw }

sub json_response {
  my ( $body, $code ) = @_;
  $code //= 200;
  return HTTP::Response->new( $code, $code == 200 ? 'OK' : 'Not Found',
    [ 'Content-Type' => 'application/json' ], $body );
}

my %OLLAMA_SHOW = (
  'llava'    => 'ollama_show_llava.json',
  'llama3.3' => 'ollama_show_llama.json',
  'llama2'   => 'ollama_show_legacy.json',
);

my $server = Test::LocalHTTPDaemon->start( sub {
  my ($req) = @_;
  my $path   = $req->uri->path;
  my $method = $req->method;
  if ( $path eq '/or/api/v1/models' && $method eq 'GET' ) {
    return json_response( '{"error":{"message":"No auth credentials found","code":401}}', 401 )
      unless ( $req->header('Authorization') // '' ) eq 'Bearer or-key';
    return json_response( fixture('openrouter_models_probe.json') );
  }
  return json_response( fixture('mistral_models_probe.json') )
    if $path eq '/mistral/v1/models' && $method eq 'GET';
  return json_response( fixture('mistral_models.json') )
    if $path eq '/mistral-old/v1/models' && $method eq 'GET';
  return json_response( fixture('lmstudio_api_v1_models.json') )
    if $path eq '/lms/api/v1/models' && $method eq 'GET';
  if ( $path eq '/ollama/api/show' && $method eq 'POST' ) {
    my $model = eval { $json->decode( $req->content )->{model} } // '';
    return json_response( fixture( $OLLAMA_SHOW{$model} ) ) if $OLLAMA_SHOW{$model};
    return json_response( qq{{"error":"model '$model' not found"}}, 404 );
  }
  if ( $path =~ m{\A/llama-(vision|text|legacy)/props\z} && $method eq 'GET' ) {
    return json_response( fixture("llamacpp_props_$1.json") );
  }
  return json_response( '{"error":"no route"}', 404 );
} );
my $base = $server->url;

# A client that dies on any request: proves a code path sends nothing.
{
  package My::ForbiddenHTTP;
  sub do_request { die "no request may be sent\n" }
}
my $forbidden = bless {}, 'My::ForbiddenHTTP';

sub sync_http { Langertha::Request::SyncHTTP->new( user_agent => LWP::UserAgent->new( timeout => 10 ) ) }

sub claims { $_[0]->supports('image_input') ? 1 : 0 }

sub error_of {
  my ($code) = @_;
  return eval { $code->(); 1 } ? '' : "$@";
}

# ---------------------------------------------------------------------------
subtest 'no probe: static answers, no request, empty store' => sub {
  for my $engine (
    Langertha::Engine::OpenRouter->new( api_key => 'k', model => 'openai/gpt-4o', _async_http => $forbidden ),
    Langertha::Engine::OllamaOpenAI->new( url => 'http://h/v1', model => 'llava', _async_http => $forbidden ),
    Langertha::Engine::LlamaCpp->new( url => 'http://h/v1', _async_http => $forbidden ),
  ) {
    is claims($engine), 0, ref($engine) . ': no static claim';
    is_deeply $engine->learned_model_capabilities, {}, ref($engine) . ': nothing learned';
  }
  my $mistral = Langertha::Engine::Mistral->new( api_key => 'k', _async_http => $forbidden );
  is claims($mistral), 1, 'Mistral default model keeps its static claim';

  # No default model and none configured: supports() answers instead of
  # croaking on chat_model (the table walk sees '').
  my $router = Langertha::Engine::OpenRouter->new( api_key => 'k', _async_http => $forbidden );
  is claims($router), 0, 'OpenRouter without a model: no claim, no croak';
};

subtest 'engines without a probe resolve to {} without a request' => sub {
  for my $engine (
    Langertha::Engine::OpenAI->new( api_key => 'k', _async_http => $forbidden ),
    Langertha::Engine::Anthropic->new( api_key => 'k', _async_http => $forbidden ),
    Langertha::Engine::TSystems->new( api_key => 'k', _async_http => $forbidden ),
  ) {
    is $engine->model_metadata_format, undef, ref($engine) . ': no metadata format';
    is_deeply $engine->probe_model_capabilities, {}, ref($engine) . ': empty result';
    is_deeply $engine->learned_model_capabilities, {}, ref($engine) . ': store stays empty';
  }
  my $ollama = Langertha::Engine::OllamaOpenAI->new( url => 'http://h/v1', _async_http => $forbidden );
  is_deeply $ollama->probe_model_capabilities, {},
    'per-model format with no model: no request, empty result';
};

# ---------------------------------------------------------------------------
# Per engine, on the default backend and on the sync LWP shim (ADR 0027 parity).
for my $backend ( [ default => sub { () } ], [ sync => sub { ( _async_http => sync_http() ) } ] ) {
  my ( $label, $http ) = @$backend;

  subtest "OpenRouter ($label): input_modalities, static no-claim + probe yes -> yes" => sub {
    my $e = Langertha::Engine::OpenRouter->new(
      url => "$base/or/api/v1", api_key => 'or-key', model => 'openai/gpt-4o', $http->() );
    is claims($e), 0, 'before the probe: no claim';
    my $learned = $e->probe_model_capabilities;
    is_deeply $learned, {
      'openai/gpt-4o'        => { image_input => 1 },
      'deepseek/deepseek-r1' => { image_input => 0 },
    }, 'every model in /models is learned (id and canonical_slug coincide here)';
    is claims($e), 1, 'after the probe: the model sees images';
    my $r1 = Langertha::Engine::OpenRouter->new( api_key => 'k', model => 'deepseek/deepseek-r1' );
    is claims($r1), 0, 'the store is per instance: a fresh engine knows nothing';
  };

  subtest "Mistral ($label): capabilities.vision per id and alias" => sub {
    my $e = Langertha::Engine::Mistral->new(
      url => "$base/mistral", api_key => 'k', model => 'mistral-large-pixtral-2411', $http->() );
    is claims($e), 0, 'static table makes no claim for this id';
    my $learned = $e->probe_model_capabilities;
    is $learned->{'mistral-small-latest'}{image_input}, 1, 'alias learned';
    is $learned->{'mistral-small-2603'}{image_input},   1, 'id learned';
    is $learned->{'codestral-latest'}{image_input},     0, 'text-only alias learned as 0';
    is claims($e), 1, 'static no-claim + probe yes -> yes';
  };

  subtest "LMStudio native + OpenAI face ($label): /api/v1/models capabilities.vision" => sub {
    for my $e (
      Langertha::Engine::LMStudio->new( url => "$base/lms", model => 'google/gemma-4-26b-a4b', $http->() ),
      Langertha::Engine::LMStudioOpenAI->new( url => "$base/lms/v1", model => 'google/gemma-4-26b-a4b', $http->() ),
    ) {
      is $e->model_metadata_url, "$base/lms/api/v1/models", ref($e) . ': native models URL';
      is claims($e), 0, ref($e) . ': no claim before the probe';
      my $learned = $e->probe_model_capabilities;
      is_deeply $learned, {
        'google/gemma-4-26b-a4b' => { image_input => 1 },
        'deepseek-r1'            => { image_input => 0 },
      }, ref($e) . ': llm entries learned, the embedding entry (no capabilities) gives no fact';
      is claims($e), 1, ref($e) . ': vision model claims after the probe';
    }
  };

  subtest "Ollama native + OllamaOpenAI ($label): /api/show capabilities" => sub {
    for my $e (
      Langertha::Engine::Ollama->new( url => "$base/ollama", model => 'llava', $http->() ),
      Langertha::Engine::OllamaOpenAI->new( url => "$base/ollama/v1", model => 'llava', $http->() ),
    ) {
      is claims($e), 0, ref($e) . ': no claim before the probe';
      is_deeply $e->probe_model_capabilities, { llava => { image_input => 1 } },
        ref($e) . ': chat_model probed by default';
      is claims($e), 1, ref($e) . ': llava sees images';
      is_deeply $e->probe_model_capabilities( models => [qw( llama3.3 llama2 )] ),
        { 'llama3.3' => { image_input => 0 } },
        ref($e) . ': one request per model; a server without capabilities gives no fact';
      is_deeply $e->learned_model_capabilities, {
        llava => { image_input => 1 }, 'llama3.3' => { image_input => 0 },
      }, ref($e) . ': facts merge into the store';
    }
  };

  subtest "LlamaCpp ($label): /props modalities.vision" => sub {
    my $vision = Langertha::Engine::LlamaCpp->new( url => "$base/llama-vision/v1", $http->() );
    is claims($vision), 0, 'no claim before the probe';
    is_deeply $vision->probe_model_capabilities, { default => { image_input => 1 } },
      'the one loaded model is keyed by the id asked about (chat_model)';
    is claims($vision), 1, 'vision server claims after the probe';

    my $text = Langertha::Engine::LlamaCpp->new( url => "$base/llama-text/v1", model => 'llama', $http->() );
    is_deeply $text->probe_model_capabilities, { llama => { image_input => 0 } }, 'text server learned as 0';
    is claims($text), 0, 'text server stays without claim';

    my $legacy = Langertha::Engine::LlamaCpp->new( url => "$base/llama-legacy/v1", $http->() );
    is_deeply $legacy->probe_model_capabilities, {}, 'a server without modalities gives no fact';
  };
}

# ---------------------------------------------------------------------------
subtest 'precedence: probe is authoritative for the models it reports' => sub {
  my $e = Langertha::Engine::Mistral->new(
    url => "$base/mistral-old", api_key => 'k', model => 'mistral-small-latest' );
  is claims($e), 1, 'static table claims mistral-small-latest';
  $e->probe_model_capabilities;
  is claims($e), 0, 'static yes + probe no -> no';
  $e->clear_learned_model_capabilities;
  is claims($e), 1, 'clear_learned_model_capabilities restores the static answer';

  my $unreported = Langertha::Engine::OpenRouter->new(
    url => "$base/or/api/v1", api_key => 'or-key', model => 'x/not-listed' );
  $unreported->probe_model_capabilities;
  is claims($unreported), 0, 'a model the document does not describe keeps its static answer';
  my $static_yes = Langertha::Engine::Mistral->new(
    url => "$base/mistral", api_key => 'k', model => 'pixtral-12b-2409' );
  $static_yes->probe_model_capabilities;
  is claims($static_yes), 1, 'static yes on an unreported model is kept';
};

subtest 'a learned yes cannot open a closed wire' => sub {
  {
    package My::ClosedRouter;
    use Moose;
    extends 'Langertha::Engine::OpenRouter';
    around engine_capabilities => sub {
      my ( $orig, $self, @rest ) = @_;
      my $caps = $self->$orig(@rest);
      delete $caps->{image_input};    # layer 2: this endpoint never carries images
      return $caps;
    };
    __PACKAGE__->meta->make_immutable;
  }
  {
    package My::AKIWithProbe;    # AKI native does not compose Role::ImageInput (layer 1)
    use Moose;
    extends 'Langertha::Engine::AKI';
    sub model_metadata_format { 'openrouter' }
    sub model_metadata_url    { "$base/or/api/v1/models" }
    around generate_http_request => sub {
      my ( $orig, $self, @args ) = @_;
      my $req = $self->$orig(@args);
      $req->header( Authorization => 'Bearer or-key' );
      return $req;
    };
    __PACKAGE__->meta->make_immutable;
  }
  my $closed = My::ClosedRouter->new( url => "$base/or/api/v1", api_key => 'or-key', model => 'openai/gpt-4o' );
  $closed->probe_model_capabilities;
  is $closed->learned_model_capabilities->{'openai/gpt-4o'}{image_input}, 1, 'the fact is learned';
  is claims($closed), 0, 'layer 2 still has the last word';

  my $aki = My::AKIWithProbe->new( api_key => 'k', model => 'openai/gpt-4o' );
  $aki->probe_model_capabilities;
  is claims($aki), 0, 'a learned yes does not assert a flag the composed roles do not grant';
};

subtest 'errors fail loud' => sub {
  my $e = Langertha::Engine::Ollama->new( url => "$base/ollama", model => 'missing' );
  my $f = $e->probe_model_capabilities_f;
  $f->await;
  ok $f->is_failed, 'a 404 fails the future';
  like scalar $f->failure, qr/Langertha::Engine::Ollama model metadata probe failed: 404/,
    'the failure names the engine and the status';
  like scalar $f->failure, qr/model 'missing' not found/, 'and carries the provider body';
  is_deeply $e->learned_model_capabilities, {}, 'nothing is stored';

  my $bad = Langertha::Engine::OpenRouter->new( url => "$base/or/api/v1", api_key => 'wrong', model => 'm' );
  like error_of( sub { $bad->probe_model_capabilities } ), qr/401/,
    'auth header is sent (a wrong key is refused)';

  like error_of( sub { $e->probe_model_capabilities( models => 'llava' ) } ), qr/must be an ArrayRef/,
    'models must be an ArrayRef';
};

subtest 'a probe on a clone does not write into its source' => sub {
  my $e = Langertha::Engine::OpenRouter->new( url => "$base/or/api/v1", api_key => 'or-key', model => 'openai/gpt-4o' );
  my $clone = $e->meta->clone_object($e);
  $clone->probe_model_capabilities;
  is claims($clone), 1, 'the clone learned';
  is claims($e), 0, 'the source did not';
};

subtest 'Manifest::Builder publishes probed facts' => sub {
  my $e = Langertha::Engine::OpenRouter->new( url => "$base/or/api/v1", api_key => 'or-key', model => 'openai/gpt-4o' );
  my @models = ( 'openai/gpt-4o', 'deepseek/deepseek-r1' );
  my $before = Langertha::Manifest::Builder->new->add_engine( $e, models => \@models )->manifest;
  ok !( grep { $_->supports('image_input') } @{ $before->models } ), 'unprobed: no model claims image_input';
  $e->probe_model_capabilities;
  my $after = Langertha::Manifest::Builder->new->add_engine( $e, models => \@models )->manifest;
  my %claim = map { $_->id => ( $_->supports('image_input') ? 1 : 0 ) } @{ $after->models };
  is_deeply \%claim, { 'openai/gpt-4o' => 1, 'deepseek/deepseek-r1' => 0 },
    'probed: each model entry carries its learned fact';
};

subtest 'ModelProbe door' => sub {
  is_deeply [ Langertha::ModelProbe->probed_capabilities ], ['image_input'], 'only image_input is learned';
  like error_of( sub { Langertha::ModelProbe->extract( 'nope', {}, [] ) } ),
    qr/unknown model_metadata_format 'nope'/, 'unknown format croaks';
  my $probe = 'Langertha::ModelProbe';
  is_deeply( $probe->extract( openrouter => [], [] ), {}, 'unexpected shape: no facts' );
  is( $probe->server_root_url('http://h:11434/v1'),  'http://h:11434',  'strips /v1' );
  is( $probe->server_root_url('http://h:11434/v1/'), 'http://h:11434',  'strips /v1/' );
  is( $probe->server_root_url('http://h:1234/x/v1'), 'http://h:1234/x', 'keeps a path prefix' );
  my $mistral = Langertha::ModelProbe->extract( mistral => { data => [
    { id => 'other',  aliases => ['shared'], capabilities => { vision => JSON::MaybeXS::false() } },
    { id => 'shared', capabilities => { vision => JSON::MaybeXS::true() } },
  ] }, [] );
  is $mistral->{shared}{image_input}, 1, "an entry's own id wins over another entry's alias";
};

done_testing;
