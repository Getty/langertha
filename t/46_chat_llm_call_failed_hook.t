#!/usr/bin/env perl
# ABSTRACT: Langertha::Chat fires plugin_llm_call_failed on every failing LLM call path and plugin_after_llm_response after a stream; the caller's error is unchanged (no network)

use strict;
use warnings;

use Test2::Bundle::More;
use Path::Tiny;
use Scalar::Util qw( blessed );

use lib path(__FILE__)->parent->child('lib')->stringify;

use Test::MockMCP;

use Langertha::Chat;
use Langertha::Engine::Virtual;
use Langertha::Virtual::Rules qw( answer tool after error );

# A plugin that records what the hooks get.
{
  package Test::Recorder;
  use Moose;
  use Future::AsyncAwait;
  extends 'Langertha::Plugin';
  has failed => ( is => 'ro', default => sub { [] } );
  has afters => ( is => 'ro', default => sub { [] } );
  async sub plugin_after_llm_response {
    my ( $self, $data, $iteration, $call ) = @_;
    push @{ $self->afters }, [ $data, $iteration, $call ];
    return $data;
  }
  async sub plugin_llm_call_failed {
    my ( $self, $error, $iteration, $call ) = @_;
    push @{ $self->failed }, [ $error, $iteration, $call ];
    return;
  }
  __PACKAGE__->meta->make_immutable;
}

# Dies in the failure hook: synchronously (no async sub) or as a failed Future.
{
  package Test::DiesSync;
  use Moose;
  extends 'Langertha::Plugin';
  sub plugin_llm_call_failed { die "sync hook exploded\n" }
  __PACKAGE__->meta->make_immutable;
}
{
  package Test::DiesAsync;
  use Moose;
  use Future::AsyncAwait;
  extends 'Langertha::Plugin';
  async sub plugin_llm_call_failed { die "async hook exploded\n" }
  __PACKAGE__->meta->make_immutable;
}

# Rewrites the answer in the after-hook.
{
  package Test::Rewrite;
  use Moose;
  use Future::AsyncAwait;
  extends 'Langertha::Plugin';
  async sub plugin_after_llm_response {
    my ( $self, $data, $iteration, $call ) = @_;
    return $data unless ref $call eq 'HASH' && $call->{stream};
    return Langertha::Response->new( content => uc $data->content );
  }
  __PACKAGE__->meta->make_immutable;
}

{
  package Test::DieObject;
  sub new { bless { what => $_[1] }, $_[0] }
}

my $mcp = Test::MockMCP->new( tools => [
  { name => 'lookup', description => 'Look something up',
    input_schema => { type => 'object', properties => { query => { type => 'string' } } },
    code => sub { my ( $self ) = @_; return $self->text_result('found') } },
] );

sub engine {
  return Langertha::Engine::Virtual->new(
    langfuse_enabled => 0,
    rules => [
      qr/\Aboom\z/      => sub { error( 500, 'upstream down' ) },
      qr/\Alimit\z/     => sub { error( 429, 'Rate limit reached' ) },
      qr/\Atool boom\z/ => sub { tool( lookup => { query => 'x' } ) },
      after('lookup')   => sub { error( 503, 'second call down' ) },
    ],
    fallback => answer( 'hello there', usage => { prompt_tokens => 3, completion_tokens => 2 } ),
  );
}

sub chat {
  my ( @plugins ) = @_;
  my $chat = Langertha::Chat->new( engine => engine(), mcp_servers => [$mcp], plugins => \@plugins );
  return ( $chat, @{ $chat->plugin_instances } );
}

# The error a plugin-less Chat gives for the same call: what "unchanged" means.
sub error_without_plugins {
  my ( $method, @args ) = @_;
  my ($chat) = chat();
  eval { $chat->$method(@args); 1 } and return undef;
  return $@;
}

subtest 'sync simple_chat: hook gets the error, caller gets it unchanged' => sub {
  my ( $chat, $rec ) = chat('+Test::Recorder');
  ok( !eval { $chat->simple_chat('boom'); 1 }, 'the call still dies' );
  my $error = $@;
  is( $error, error_without_plugins( simple_chat => 'boom' ), 'same error as without plugins' );
  is( scalar @{ $rec->failed }, 1, 'plugin_llm_call_failed fired once' );
  my ( $seen, $iteration, $call ) = @{ $rec->failed->[0] };
  is( $seen, $error, 'the hook saw the error the caller got' );
  is( $iteration, 1, 'iteration 1' );
  ok( !$call->{stream}, 'not a stream' );
  isa_ok( $call->{http_response}, 'HTTP::Response' );
  is( $call->{http_response}->code, 500, 'http_response is the server answer' );
  is( scalar @{ $rec->afters }, 0, 'no after-hook for a failed call' );
};

subtest 'simple_chat_f: the failed Future is unchanged' => sub {
  my ( $chat, $rec ) = chat('+Test::Recorder');
  my $f = $chat->simple_chat_f('boom');
  $f->await;
  ok( $f->is_failed, 'the future failed' );
  my ($plain) = chat();
  my $g = $plain->simple_chat_f('boom');
  $g->await;
  is_deeply( [ map { "$_" } $f->failure ], [ map { "$_" } $g->failure ], 'same failure as without plugins' );
  is( scalar @{ $rec->failed }, 1, 'hook fired once' );
  is( $rec->failed->[0][0], ( $f->failure )[0], 'the hook saw the failure' );
  is( $rec->failed->[0][2]{http_response}->code, 500, 'with the server answer' );
};

subtest 'sync simple_chat_stream: success fires the after-hook with a Response' => sub {
  my ( $chat, $rec ) = chat('+Test::Recorder');
  my @chunks;
  my $text = $chat->simple_chat_stream( sub { push @chunks, $_[0] }, 'hi' );
  is( $text, 'hello there', 'the streamed text' );
  ok( scalar @chunks, 'the callback got chunks' );
  is( scalar @{ $rec->afters }, 1, 'plugin_after_llm_response fired once' );
  my ( $response, $iteration, $call ) = @{ $rec->afters->[0] };
  isa_ok( $response, 'Langertha::Response' );
  is( $response->content, 'hello there', 'with the whole text' );
  is( $response->finish_reason, 'stop', 'the finish reason' );
  is( $response->model, 'virtual', 'the model the stream named' );
  ok( $response->has_usage, 'the usage the stream carried' );
  is( $response->usage->input_tokens, 3, '... its input tokens' );
  ok( !$response->has_ttft, 'no ttft: the sync path reads the body first' );
  ok( $call->{stream}, 'stream flag' );
  is( $iteration, 1, 'iteration 1' );
  is( scalar @{ $rec->failed }, 0, 'no failure hook' );
};

subtest 'sync simple_chat_stream: failure' => sub {
  my ( $chat, $rec ) = chat('+Test::Recorder');
  ok( !eval { $chat->simple_chat_stream( sub { }, 'limit' ); 1 }, 'dies' );
  my $error = $@;
  is( $error, error_without_plugins( simple_chat_stream => sub { }, 'limit' ), 'same error as without plugins' );
  my ( $seen, $iteration, $call ) = @{ $rec->failed->[0] };
  is( $seen, $error, 'hook saw it' );
  ok( $call->{stream}, 'stream flag on the failure' );
  is( $call->{http_response}->code, 429, 'the 429 answer' );
};

subtest 'simple_chat_stream_realtime_f: success, ttft, rewrite' => sub {
  my ( $chat, $rec, undef ) = chat( '+Test::Recorder', '+Test::Rewrite' );
  my @chunks;
  my ( $content, $chunks, $timing, $thinking ) =
    $chat->simple_chat_stream_realtime_f( sub { push @chunks, $_[0] }, 'hi' )->get;
  is( join( '', map { $_->content } @chunks ), 'hello there', 'the callback got the raw stream' );
  is( $content, 'HELLO THERE', 'the returned text is what the hooks returned' );
  is( scalar @$chunks, scalar @chunks, 'the chunks' );
  ok( defined $timing->{ttft_seconds}, 'ttft measured' );
  my ( $response, undef, $call ) = @{ $rec->afters->[0] };
  ok( $response->has_ttft, 'the Response carries the ttft' );
  is( $response->ttft_seconds, $timing->{ttft_seconds}, '... the measured one' );
  ok( $call->{stream}, 'stream flag' );

  my ($plain) = chat();
  my ($text) = $plain->simple_chat_stream_realtime_f( undef, 'hi' )->get;
  is( $text, 'hello there', 'no plugins: the text unchanged, undef callback allowed' );
};

subtest 'simple_chat_stream_realtime_f: failures keep category and details' => sub {
  my ( $chat, $rec ) = chat('+Test::Recorder');
  my $f = $chat->simple_chat_stream_realtime_f( undef, 'limit' );
  $f->await;
  ok( $f->is_failed, 'a 429 fails the future' );
  like( ( $f->failure )[0], qr/streaming request failed: 429/, 'the engine error text' );
  is( $rec->failed->[0][2]{http_response}->code, 429, 'the hook got the 429 answer' );
  like( $rec->failed->[0][2]{http_response}->content, qr/Rate limit reached/, '... with its error body' );

  my $dies = Test::DieObject->new('callback');
  my $g = $chat->simple_chat_stream_realtime_f( sub { die $dies }, 'hi' );
  $g->await;
  my @failure = $g->failure;
  is( $failure[0], $dies, 'the callback exception object, unchanged' );
  is( $failure[1], 'http', 'the category survives' );
  isa_ok( $failure[2], 'HTTP::Response' );
  is( $rec->failed->[1][0], $dies, 'the hook saw the same object' );
  ok( $rec->failed->[1][2]{stream}, 'stream flag' );
};

subtest 'tool loops: failure in the second iteration' => sub {
  for my $method (qw( simple_chat_with_tools simple_chat_with_tools_f )) {
    my ( $chat, $rec ) = chat('+Test::Recorder');
    my $error;
    if ( $method =~ /_f\z/ ) {
      my $f = $chat->$method('tool boom');
      $f->await;
      ok( $f->is_failed, "$method: failed" );
      $error = ( $f->failure )[0];
    }
    else {
      ok( !eval { $chat->$method('tool boom'); 1 }, "$method: dies" );
      $error = $@;
    }
    like( $error, qr/tool chat request failed: 503/, "$method: the loop's error text" );
    is( scalar @{ $rec->failed }, 1, "$method: hook fired once" );
    is( $rec->failed->[0][1], 2, "$method: in iteration 2" );
    is( $rec->failed->[0][0], $error, "$method: the same error" );
    is( $rec->failed->[0][2]{http_response}->code, 503, "$method: the answer" );
    is( scalar @{ $rec->afters }, 1, "$method: iteration 1 had its after-hook" );
  }
};

subtest 'a plugin dying in the failure hook does not mask the error' => sub {
  for my $dier (qw( +Test::DiesSync +Test::DiesAsync )) {
    my ( $chat, undef, $rec ) = chat( $dier, '+Test::Recorder' );
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    ok( !eval { $chat->simple_chat('boom'); 1 }, "$dier: still dies" );
    is( $@, error_without_plugins( simple_chat => 'boom' ), "$dier: with the original error" );
    is( scalar @{ $rec->failed }, 1, "$dier: the next plugin still heard of it" );
    is( scalar @warnings, 1, "$dier: one warning" );
    like( $warnings[0], qr/died in plugin_llm_call_failed: (?:a?sync) hook exploded/, "$dier: names the hook" );

    my $f = $chat->simple_chat_f('boom');
    $f->await;
    like( ( $f->failure )[0], qr/request failed: 500/, "$dier: async keeps the original failure" );
  }
};

subtest 'a plugin without the hook (the base class default) changes nothing' => sub {
  my ($chat) = chat('+Langertha::Plugin');
  ok( !eval { $chat->simple_chat('boom'); 1 }, 'dies' );
  is( $@, error_without_plugins( simple_chat => 'boom' ), 'unchanged' );
};

done_testing;
