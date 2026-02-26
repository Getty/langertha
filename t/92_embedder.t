#!/usr/bin/env perl
# ABSTRACT: Tests for Langertha::Embedder

use strict;
use warnings;

use Test2::Bundle::More;

use Langertha::Embedder;

# --- Mock engine with Embedding role ---

{
  package MockRequest;
  sub new { bless { response_call => $_[1] }, $_[0] }
  sub response_call { $_[0]->{response_call} }
}

{
  package MockUserAgent;
  sub new { bless {}, $_[0] }
  sub request { 'fake_response' }
}

{
  package MockEmbeddingEngine;
  use Moose;

  has model => (is => 'ro', default => 'default-embed-model');
  has embedding_model => (is => 'ro', lazy => 1, default => sub { $_[0]->model });
  has user_agent => (is => 'ro', default => sub { MockUserAgent->new });

  # Track what model was used in the last request
  has last_request_model => (is => 'rw');

  sub does {
    my ($self, $role) = @_;
    return 1 if $role eq 'Langertha::Role::Embedding';
    return $self->SUPER::does($role);
  }

  sub embedding_request {
    my ( $self, $input, %extra ) = @_;
    my $model = $extra{model} // $self->embedding_model;
    $self->last_request_model($model);
    return MockRequest->new(sub { [0.1, 0.2, 0.3] });
  }

  sub simple_embedding {
    my ( $self, $text ) = @_;
    $self->last_request_model($self->embedding_model);
    return [0.1, 0.2, 0.3];
  }

  __PACKAGE__->meta->make_immutable;
}

# --- Mock engine WITHOUT Embedding role ---

{
  package MockChatOnlyEngine;
  use Moose;

  sub does { 0 }

  __PACKAGE__->meta->make_immutable;
}

# --- Tests ---

subtest 'Embedder instantiation' => sub {
  my $engine = MockEmbeddingEngine->new;
  my $embedder = Langertha::Embedder->new(engine => $engine);

  ok($embedder, 'created');
  is($embedder->engine, $engine, 'engine set');
  ok(!$embedder->has_model, 'no model override');
};

subtest 'Embedder with model override' => sub {
  my $engine = MockEmbeddingEngine->new;
  my $embedder = Langertha::Embedder->new(
    engine => $engine,
    model  => 'custom-embed',
  );

  ok($embedder->has_model, 'has model');
  is($embedder->model, 'custom-embed', 'model value');
};

subtest 'simple_embedding delegates to engine without model override' => sub {
  my $engine = MockEmbeddingEngine->new;
  my $embedder = Langertha::Embedder->new(engine => $engine);

  my $vec = $embedder->simple_embedding('hello');
  is_deeply($vec, [0.1, 0.2, 0.3], 'got embedding vector');
  is($engine->last_request_model, 'default-embed-model', 'used engine default model');
};

subtest 'simple_embedding with model override uses custom model' => sub {
  my $engine = MockEmbeddingEngine->new;
  my $embedder = Langertha::Embedder->new(
    engine => $engine,
    model  => 'nomic-embed-v2',
  );

  my $vec = $embedder->simple_embedding('hello');
  is_deeply($vec, [0.1, 0.2, 0.3], 'got embedding vector');
  is($engine->last_request_model, 'nomic-embed-v2', 'used overridden model');
};

subtest 'simple_embedding dies on engine without Embedding role' => sub {
  my $engine = MockChatOnlyEngine->new;
  my $embedder = Langertha::Embedder->new(engine => $engine);

  eval { $embedder->simple_embedding('hello') };
  like($@, qr/does not support embeddings/, 'dies with useful error');
};

subtest 'Embedder is compatible as Raider embedding_engine' => sub {
  # Raider calls ->simple_embedding() on whatever is in embedding_engine.
  # Embedder provides that method, so it should work.
  my $engine = MockEmbeddingEngine->new;
  my $embedder = Langertha::Embedder->new(
    engine => $engine,
    model  => 'nomic-embed',
  );

  ok($embedder->can('simple_embedding'), 'has simple_embedding method');

  my $vec = $embedder->simple_embedding('test');
  ok(ref $vec eq 'ARRAY', 'returns arrayref');
};

subtest 'Embedder works as SQLite::VecDB embedding parameter' => sub {
  # SQLite::VecDB calls ->simple_embedding($text) on the embedding object.
  # That's all it needs — duck typing.
  my $engine = MockEmbeddingEngine->new;
  my $embedder = Langertha::Embedder->new(
    engine => $engine,
    model  => 'nomic-embed',
  );

  # Simulate what SQLite::VecDB does internally
  my $vec = $embedder->simple_embedding('some document text');
  ok(ref $vec eq 'ARRAY', 'returns arrayref (VecDB compatible)');
  is(scalar @$vec, 3, 'vector has expected dimensions');
};

# --- Plugin tests ---

{
  package EmbedTestPlugin::Logger;
  use Moose;
  use Future::AsyncAwait;
  extends 'Langertha::Plugin';

  has log => (is => 'ro', default => sub { [] });

  async sub plugin_before_embedding {
    my ($self, $text) = @_;
    push @{$self->log}, { event => 'before', text => $text };
    return $text;
  }

  async sub plugin_after_embedding {
    my ($self, $text, $vector) = @_;
    push @{$self->log}, { event => 'after', text => $text, dims => scalar @$vector };
    return $vector;
  }

  __PACKAGE__->meta->make_immutable;
}

{
  package EmbedTestPlugin::TextTransformer;
  use Moose;
  use Future::AsyncAwait;
  extends 'Langertha::Plugin';

  has transform_log => (is => 'ro', default => sub { [] });

  async sub plugin_before_embedding {
    my ($self, $text) = @_;
    my $new_text = "prefix: $text";
    push @{$self->transform_log}, $new_text;
    return $new_text;
  }

  __PACKAGE__->meta->make_immutable;
}

subtest 'Embedder fires plugin hooks' => sub {
  my $engine = MockEmbeddingEngine->new;
  my $embedder = Langertha::Embedder->new(
    engine  => $engine,
    plugins => ['+EmbedTestPlugin::Logger'],
  );

  my $vec = $embedder->simple_embedding('test text');
  is_deeply($vec, [0.1, 0.2, 0.3], 'got vector');

  my $plugin = $embedder->_plugin_instances->[0];
  is(scalar @{$plugin->log}, 2, 'two events');
  is($plugin->log->[0]{event}, 'before', 'before event');
  is($plugin->log->[0]{text}, 'test text', 'text passed');
  is($plugin->log->[1]{event}, 'after', 'after event');
  is($plugin->log->[1]{dims}, 3, 'vector dimensions passed');
};

subtest 'Embedder plugin can transform input text' => sub {
  my $engine = MockEmbeddingEngine->new;
  my $embedder = Langertha::Embedder->new(
    engine  => $engine,
    plugins => ['+EmbedTestPlugin::TextTransformer'],
  );

  $embedder->simple_embedding('hello');
  my $plugin = $embedder->_plugin_instances->[0];
  is($plugin->transform_log->[0], 'prefix: hello', 'text was transformed');
};

subtest 'Embedder has PluginHost role' => sub {
  my $engine = MockEmbeddingEngine->new;
  my $embedder = Langertha::Embedder->new(engine => $engine);

  ok($embedder->does('Langertha::Role::PluginHost'), 'has PluginHost');
  is_deeply($embedder->plugins, [], 'empty plugins by default');
  is_deeply($embedder->_plugin_instances, [], 'no instances');
};

done_testing;
