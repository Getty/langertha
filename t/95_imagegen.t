#!/usr/bin/env perl
# ABSTRACT: Tests for Langertha::ImageGen

use strict;
use warnings;

use Test2::Bundle::More;

use Langertha::ImageGen;

# --- Mock engine with ImageGeneration role ---

{
  package MockImageRequest;
  sub new { bless { response_call => $_[1] }, $_[0] }
  sub response_call { $_[0]->{response_call} }
}

{
  package MockImageUserAgent;
  sub new { bless {}, $_[0] }
  sub request { 'fake_response' }
}

{
  package MockImageEngine;
  use Moose;

  has model => (is => 'ro', default => 'dall-e-3');
  has image_model => (is => 'ro', lazy => 1, default => sub { $_[0]->model });
  has user_agent => (is => 'ro', default => sub { MockImageUserAgent->new });

  has last_request_model => (is => 'rw');
  has last_request_extra => (is => 'rw');

  sub does {
    my ($self, $role) = @_;
    return 1 if $role eq 'Langertha::Role::ImageGeneration';
    return $self->SUPER::does($role);
  }

  sub image_request {
    my ($self, $prompt, %extra) = @_;
    $self->last_request_model($extra{model} // $self->image_model);
    $self->last_request_extra(\%extra);
    return MockImageRequest->new(sub {
      { url => 'https://example.com/image.png', revised_prompt => $prompt }
    });
  }

  sub simple_image {
    my ($self, $prompt) = @_;
    $self->last_request_model($self->image_model);
    return { url => 'https://example.com/default.png', revised_prompt => $prompt };
  }

  __PACKAGE__->meta->make_immutable;
}

# --- Mock engine WITHOUT ImageGeneration ---

{
  package MockChatOnlyEngine2;
  use Moose;
  sub does { 0 }
  __PACKAGE__->meta->make_immutable;
}

# --- Tests ---

subtest 'ImageGen instantiation' => sub {
  my $engine = MockImageEngine->new;
  my $ig = Langertha::ImageGen->new(engine => $engine);

  ok($ig, 'created');
  is($ig->engine, $engine, 'engine set');
  ok(!$ig->has_model, 'no model override');
  ok(!$ig->has_size, 'no size override');
  ok(!$ig->has_quality, 'no quality override');
};

subtest 'ImageGen with all options' => sub {
  my $engine = MockImageEngine->new;
  my $ig = Langertha::ImageGen->new(
    engine  => $engine,
    model   => 'dall-e-2',
    size    => '512x512',
    quality => 'standard',
  );

  ok($ig->has_model, 'has model');
  is($ig->model, 'dall-e-2', 'model value');
  ok($ig->has_size, 'has size');
  is($ig->size, '512x512', 'size value');
  ok($ig->has_quality, 'has quality');
  is($ig->quality, 'standard', 'quality value');
};

subtest 'simple_image delegates to engine without overrides' => sub {
  my $engine = MockImageEngine->new;
  my $ig = Langertha::ImageGen->new(engine => $engine);

  my $result = $ig->simple_image('A cat');
  is_deeply($result, {
    url => 'https://example.com/default.png',
    revised_prompt => 'A cat',
  }, 'got image result');
  is($engine->last_request_model, 'dall-e-3', 'used engine default model');
};

subtest 'simple_image with model override' => sub {
  my $engine = MockImageEngine->new;
  my $ig = Langertha::ImageGen->new(
    engine => $engine,
    model  => 'dall-e-2',
  );

  my $result = $ig->simple_image('A dog');
  ok($result, 'got result');
  is($engine->last_request_model, 'dall-e-2', 'used overridden model');
};

subtest 'simple_image with size and quality overrides' => sub {
  my $engine = MockImageEngine->new;
  my $ig = Langertha::ImageGen->new(
    engine  => $engine,
    size    => '1792x1024',
    quality => 'hd',
  );

  $ig->simple_image('A landscape');
  my $extra = $engine->last_request_extra;
  is($extra->{size}, '1792x1024', 'size in extra');
  is($extra->{quality}, 'hd', 'quality in extra');
};

subtest 'simple_image dies on engine without ImageGeneration role' => sub {
  my $engine = MockChatOnlyEngine2->new;
  my $ig = Langertha::ImageGen->new(engine => $engine);

  eval { $ig->simple_image('A cat') };
  like($@, qr/does not support image generation/, 'dies with useful error');
};

subtest 'multiple ImageGen share same engine' => sub {
  my $engine = MockImageEngine->new;

  my $hd = Langertha::ImageGen->new(
    engine  => $engine,
    quality => 'hd',
    size    => '1024x1024',
  );

  my $fast = Langertha::ImageGen->new(
    engine  => $engine,
    model   => 'dall-e-2',
    size    => '256x256',
  );

  $hd->simple_image('HD image');
  is($engine->last_request_extra->{quality}, 'hd', 'hd quality');
  is($engine->last_request_extra->{size}, '1024x1024', 'hd size');

  $fast->simple_image('Fast image');
  is($engine->last_request_model, 'dall-e-2', 'fast model');
  is($engine->last_request_extra->{size}, '256x256', 'fast size');
};

# --- Plugin tests ---

{
  package ImageTestPlugin::Logger;
  use Moose;
  use Future::AsyncAwait;
  extends 'Langertha::Plugin';

  has log => (is => 'ro', default => sub { [] });

  async sub plugin_before_image_gen {
    my ($self, $prompt) = @_;
    push @{$self->log}, { event => 'before', prompt => $prompt };
    return $prompt;
  }

  async sub plugin_after_image_gen {
    my ($self, $prompt, $result) = @_;
    push @{$self->log}, { event => 'after', prompt => $prompt };
    return $result;
  }

  __PACKAGE__->meta->make_immutable;
}

{
  package ImageTestPlugin::PromptEnhancer;
  use Moose;
  use Future::AsyncAwait;
  extends 'Langertha::Plugin';

  has enhance_log => (is => 'ro', default => sub { [] });

  async sub plugin_before_image_gen {
    my ($self, $prompt) = @_;
    my $enhanced = "high quality, detailed: $prompt";
    push @{$self->enhance_log}, $enhanced;
    return $enhanced;
  }

  __PACKAGE__->meta->make_immutable;
}

subtest 'ImageGen fires plugin hooks' => sub {
  my $engine = MockImageEngine->new;
  my $ig = Langertha::ImageGen->new(
    engine  => $engine,
    plugins => ['+ImageTestPlugin::Logger'],
  );

  my $result = $ig->simple_image('A cat');
  ok($result, 'got result');

  my $plugin = $ig->_plugin_instances->[0];
  is(scalar @{$plugin->log}, 2, 'two events');
  is($plugin->log->[0]{event}, 'before', 'before event');
  is($plugin->log->[0]{prompt}, 'A cat', 'prompt passed');
  is($plugin->log->[1]{event}, 'after', 'after event');
  is($plugin->log->[1]{prompt}, 'A cat', 'prompt in after');
};

subtest 'ImageGen plugin can enhance prompt' => sub {
  my $engine = MockImageEngine->new;
  my $ig = Langertha::ImageGen->new(
    engine  => $engine,
    plugins => ['+ImageTestPlugin::PromptEnhancer'],
  );

  my $result = $ig->simple_image('a landscape');
  is($result->{revised_prompt}, 'high quality, detailed: a landscape',
    'enhanced prompt reached engine');

  my $plugin = $ig->_plugin_instances->[0];
  is($plugin->enhance_log->[0], 'high quality, detailed: a landscape',
    'enhancer was called');
};

subtest 'ImageGen has PluginHost role' => sub {
  my $engine = MockImageEngine->new;
  my $ig = Langertha::ImageGen->new(engine => $engine);

  ok($ig->does('Langertha::Role::PluginHost'), 'has PluginHost');
  is_deeply($ig->plugins, [], 'empty plugins by default');
  is_deeply($ig->_plugin_instances, [], 'no instances');
};

subtest 'Langfuse plugin traces ImageGen' => sub {
  require Langertha::Plugin::Langfuse;

  my $engine = MockImageEngine->new;
  my $lf = Langertha::Plugin::Langfuse->new(
    host       => Langertha::ImageGen->new(engine => $engine),
    public_key => 'pk-test',
    secret_key => 'sk-test',
    trace_name => 'image-gen',
  );

  my $ig = Langertha::ImageGen->new(
    engine  => $engine,
    plugins => [$lf],
  );

  $ig->simple_image('A space cat');

  my @types = map { $_->{type} } @{$lf->_batch};
  is_deeply(\@types, ['trace-create', 'generation-create', 'trace-create'],
    'trace + generation + trace update for image gen');

  my $trace = $lf->_batch->[0];
  is($trace->{body}{name}, 'image-gen', 'trace name from config');
  is($trace->{body}{input}, 'A space cat', 'trace input is prompt');

  my $gen = $lf->_batch->[1];
  is($gen->{body}{name}, 'image-generation', 'generation named image-generation');
  is($gen->{body}{input}, 'A space cat', 'generation input is prompt');

  my $update = $lf->_batch->[2];
  ok($update->{body}{output}, 'trace updated with result');
};

# --- Real OpenAI engine integration ---

subtest 'ImageGen with real OpenAI engine builds correct request' => sub {
  use Langertha::Engine::OpenAI;

  my $engine = Langertha::Engine::OpenAI->new(
    api_key => 'test-key',
    model   => 'gpt-4o-mini',
  );

  ok($engine->does('Langertha::Role::ImageGeneration'), 'OpenAI has ImageGeneration role');
  is($engine->image_model, 'gpt-image-1', 'default image_model');

  # Build request without sending
  my $request = $engine->image_request('A cat in space');
  ok($request, 'image_request returns request object');
  is($request->method, 'POST', 'POST method');
  like($request->uri, qr{/images/generations$}, 'correct endpoint');

  # Check request body
  my $body = JSON::MaybeXS->new->decode($request->content);
  is($body->{prompt}, 'A cat in space', 'prompt in body');
  is($body->{model}, 'gpt-image-1', 'model in body');
};

subtest 'ImageGen wrapper with OpenAI engine overrides model' => sub {
  use Langertha::Engine::OpenAI;

  my $engine = Langertha::Engine::OpenAI->new(
    api_key => 'test-key',
    model   => 'gpt-4o-mini',
  );

  my $ig = Langertha::ImageGen->new(
    engine  => $engine,
    model   => 'dall-e-3',
    size    => '1024x1024',
    quality => 'hd',
  );

  # Build request via the wrapper (captures the request before sending)
  my $request = $engine->image_request('A landscape', $ig->_extra);
  my $body = JSON::MaybeXS->new->decode($request->content);
  is($body->{model}, 'dall-e-3', 'model overridden to dall-e-3');
  is($body->{size}, '1024x1024', 'size passed through');
  is($body->{quality}, 'hd', 'quality passed through');
  is($body->{prompt}, 'A landscape', 'prompt set');
};

done_testing;
