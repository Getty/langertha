#!/usr/bin/env perl
# ABSTRACT: image_input is model-scoped: the model sees the image, not merely the wire (k266)

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;
use Path::Tiny qw( path );
use Module::Runtime qw( use_module );

use Langertha::Content::Image;

# karr k266 (ADR 0019 k266 Update): knarr's /api/show "vision" and the
# skeid/knarr manifests need to know whether a MODEL sees an image. A flag that
# only said "the wire accepts an image part" would be true on nearly every
# engine and useless; a wrong yes sends images to a text-only model that
# ignores them, a wrong no hides vision. So image_input is resolved per
# chat_model: all-vision families keep it minus text-only exceptions, other
# cloud engines allowlist their vision models, and engines whose model the
# client cannot know (gateways, self-hosted, shims) make no claim. The flag is
# advisory and must never block an image from being sent.

delete @ENV{ grep { /\ALANGERTHA_/ } keys %ENV };

sub engine {
  my ( $name, %args ) = @_;
  return use_module("Langertha::Engine::$name")
    ->new( api_key => 'k', url => 'http://h.example:1/v1', %args );
}

sub claims {
  my ( $name, @model ) = @_;
  return engine( $name, @model ? ( model => $model[0] ) : () )->supports('image_input') ? 1 : 0;
}

# ---------------------------------------------------------------------------
# 1. Every chat engine's default model, per the advisor table (2026-09-25).
#    Engines without a default model are probed with a neutral id.
# ---------------------------------------------------------------------------
my %DEFAULT = (
  # all-vision families
  OpenAI            => 1,  # gpt-5.6-terra
  OpenAIResponses   => 1,  # inherits OpenAI's table
  Anthropic         => 1,  # claude-sonnet-5
  Gemini            => 1,  # gemini-3-flash-preview
  Hetzner           => 1,  # Qwen/Qwen3.6-35B-A3B-FP8
  # allowlisted cloud engines, default model is a vision model
  DeepSeek          => 1,  # deepseek-flash (V4.1)
  Mistral           => 1,  # mistral-small-latest (Small 4)
  XAI               => 1,  # grok-4.7
  MiniMax           => 1,  # MiniMax-M3
  MiniMaxAnthropic  => 1,  # MiniMax-M3
  Moonshot          => 1,  # kimi-k3
  # allowlisted, default is a preset -> no claim
  Perplexity        => 0,  # sonar
  # cloud, no verified allowlist yet
  Cerebras          => 0,
  Scaleway          => 0,
  TSystems          => 0,
  Groq              => 0,
  AKIOpenAI         => 0,
  NousResearch      => 0,
  # shims
  MoonshotAnthropic => 0,
  AKIAnthropic      => 0,
  LMStudioAnthropic => 0,
  # gateways
  OpenRouter        => 0,
  HuggingFace       => 0,
  Replicate         => 0,
  # self-hosted
  vLLM              => 0,
  VLLMHook          => 0,
  SGLang            => 0,
  LlamaCpp          => 0,
  LMStudio          => 0,
  LMStudioOpenAI    => 0,
  Ollama            => 0,
  OllamaOpenAI      => 0,
  # native wire unverified: the role is not composed at all
  AKI               => 0,
);
my %NO_DEFAULT_MODEL = map { $_ => 1 } qw( Groq OpenRouter HuggingFace Replicate VLLMHook OllamaOpenAI );

for my $name ( sort keys %DEFAULT ) {
  my @model = $NO_DEFAULT_MODEL{$name} ? ('some-model') : ();
  is claims( $name, @model ), $DEFAULT{$name},
    "$name default: image_input " . ( $DEFAULT{$name} ? 'claimed' : 'not claimed' );
}

# Guard: a new chat engine must take a position here. OpenAIBase composes
# Role::ImageInput, so a new subclass would otherwise inherit a silent claim.
{
  my @unlisted;
  my @files = path('lib/Langertha/Engine')->children(qr/\.pm\z/);
  for my $file ( sort { $a cmp $b } @files ) {
    ( my $name = $file->basename ) =~ s/\.pm\z//;
    next if $name =~ /Base\z/ || $name eq 'Remote';
    my $class = use_module("Langertha::Engine::$name");
    next unless $class->does('Langertha::Role::Chat');
    push @unlisted, $name unless exists $DEFAULT{$name};
  }
  is_deeply \@unlisted, [], 'every chat engine has a decided image_input default';
}

# ---------------------------------------------------------------------------
# 2. The role marks the wire; the flag marks the model. Engines whose wire
#    carries images since k267 compose the role even where they do not claim.
# ---------------------------------------------------------------------------
for my $name (qw( OpenAIResponses Perplexity Ollama LMStudio vLLM OpenRouter AKIAnthropic )) {
  ok engine( $name, model => 'm' )->does('Langertha::Role::ImageInput'),
    "$name composes Role::ImageInput (wire carries images)";
}
ok !engine( 'AKI', model => 'm' )->does('Langertha::Role::ImageInput'),
  'AKI native does not compose Role::ImageInput (wire unverified)';

# ---------------------------------------------------------------------------
# 3. Model patterns, both directions, inside one engine.
# ---------------------------------------------------------------------------
my @ROWS = (
  # engine            model                          claim
  [ OpenAI          => 'gpt-4o'                      => 1 ],
  [ OpenAI          => 'gpt-4-turbo'                 => 1 ],
  [ OpenAI          => 'o3'                          => 1 ],
  [ OpenAI          => 'gpt-future-9'                => 1 ],  # family default
  [ OpenAI          => 'gpt-3.5-turbo'               => 0 ],
  [ OpenAI          => 'gpt-4'                       => 0 ],
  [ OpenAI          => 'gpt-4-0613'                  => 0 ],
  [ OpenAI          => 'gpt-4-1106-preview'          => 0 ],
  [ OpenAI          => 'o1-mini'                     => 0 ],
  [ OpenAI          => 'o3-mini'                     => 0 ],
  [ OpenAI          => 'gpt-4o-audio-preview'        => 0 ],
  [ OpenAI          => 'text-embedding-3-large'      => 0 ],
  [ OpenAIResponses => 'gpt-5.5-pro'                 => 1 ],
  [ OpenAIResponses => 'gpt-3.5-turbo'               => 0 ],
  [ Anthropic       => 'claude-3-haiku-20240307'     => 1 ],
  [ Anthropic       => 'claude-opus-5'               => 1 ],
  [ Anthropic       => 'claude-2.1'                  => 0 ],
  [ Anthropic       => 'claude-instant-1.2'          => 0 ],
  [ Gemini          => 'gemini-2.5-pro'              => 1 ],
  [ Gemini          => 'gemini-1.5-flash'            => 1 ],
  [ Gemini          => 'gemini-1.0-pro'              => 0 ],
  [ Gemini          => 'gemini-2.5-flash-preview-tts'=> 0 ],
  [ Gemini          => 'text-embedding-004'          => 0 ],
  [ Gemini          => 'gemma-3-27b-it'              => 0 ],
  [ Hetzner         => 'Qwen3.8-27B'                 => 1 ],
  [ DeepSeek        => 'deepseek-v4-pro'             => 0 ],
  [ DeepSeek        => 'deepseek-chat'               => 0 ],
  [ Mistral         => 'pixtral-large-latest'        => 1 ],
  [ Mistral         => 'codestral-latest'            => 0 ],
  [ XAI             => 'grok-4.7-fast'               => 1 ],
  [ XAI             => 'grok-3'                      => 0 ],
  [ XAI             => 'grok-4.75'                   => 0 ],  # multi-digit guard
  [ MiniMax         => 'MiniMax-M2.7'                => 0 ],
  [ MiniMaxAnthropic=> 'MiniMax-M2.5'                => 0 ],
  [ Moonshot        => 'kimi-k2.6'                   => 0 ],
  [ Perplexity      => 'openai/gpt-5.6-luna'         => 1 ],
  [ Perplexity      => 'anthropic/claude-sonnet-5'   => 1 ],
  [ Perplexity      => 'google/gemini-3-flash'       => 1 ],
  [ Perplexity      => 'openai/gpt-oss-120b'         => 0 ],
  [ Perplexity      => 'sonar-pro'                   => 0 ],
  # no-claim engines stay silent even for a well-known vision model
  [ OpenRouter      => 'openai/gpt-4o'               => 0 ],
  [ vLLM            => 'Qwen/Qwen2.5-VL-7B-Instruct' => 0 ],
  [ Ollama          => 'llava'                       => 0 ],
  [ MoonshotAnthropic => 'kimi-k3'                   => 0 ],
  [ Groq            => 'meta-llama/llama-4-scout-17b-16e-instruct' => 0 ],
);
for my $row (@ROWS) {
  my ( $name, $model, $want ) = @$row;
  is claims( $name, $model ), $want,
    "$name $model: image_input " . ( $want ? 'claimed' : 'not claimed' );
}

# Same engine, different model => different answer (the flag is model-scoped).
isnt claims( OpenAI => 'gpt-4o' ), claims( OpenAI => 'gpt-3.5-turbo' ),
  'OpenAI: two models disagree';
isnt claims( MiniMax => 'MiniMax-M3' ), claims( MiniMax => 'MiniMax-M2.7' ),
  'MiniMax: two models disagree';

# The catch-all row also holds for an empty model id (ADR 0019 k209 Update).
is claims( DeepSeek => '' ), 0, 'DeepSeek with an empty model makes no claim';

# ---------------------------------------------------------------------------
# 4. Advisory: no claim never blocks. An image on a no-claim engine/model is
#    serialized and sent exactly as on a claiming one.
# ---------------------------------------------------------------------------
{
  my $json = JSON::MaybeXS->new( canonical => 1, utf8 => 1 );
  my $img  = Langertha::Content::Image->from_base64( 'Zm9v', media_type => 'image/png' );
  my $msg  = { role => 'user', content => [ 'what is this?', $img ] };
  my $off  = engine( Scaleway => model => 'llama-3.1-8b-instruct' );
  my $on   = engine( OpenAI   => model => 'gpt-4o' );
  ok !$off->supports('image_input'), 'Scaleway llama-3.1-8b makes no claim';
  my ( $body_off, $body_on ) = map {
    my $e = $_;
    my $req = eval { $e->chat($msg) };
    ok defined $req, ref($e) . ': the request is built' or diag $@;
    $req ? $json->decode( $req->content ) : {};
  } $off, $on;
  is_deeply $body_off->{messages}[-1], $body_on->{messages}[-1],
    'the image part goes on the wire with or without the claim';
  is $body_off->{messages}[-1]{content}[1]{type}, 'image_url', 'the image part is there';
}

done_testing;
