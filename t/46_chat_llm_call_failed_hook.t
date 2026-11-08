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

# Dies in the after-hook; records the failure hooks it gets.
{
  package Test::Bomb;
  use Moose;
  use Future::AsyncAwait;
  extends 'Test::Recorder';
  async sub plugin_after_llm_response { die "after-hook bomb\n" }
  __PACKAGE__->meta->make_immutable;
}

# Its failure hook returns a cancelled Future, or a pending one the test
# cancels later.
{
  package Test::Cancelled;
  use Moose;
  extends 'Langertha::Plugin';
  has pending => ( is => 'rw', default => 0 );
  has futures => ( is => 'ro', default => sub { [] } );
  sub plugin_llm_call_failed {
    my ( $self ) = @_;
    my $future = Future->new;
    push @{ $self->futures }, $future;
    $future->cancel unless $self->pending;
    return $future;
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
    is( "$@", error_without_plugins( simple_chat => 'boom' ), "$dier: with the original error" );
    is( scalar @{ $rec->failed }, 1, "$dier: the next plugin still heard of it" );
    is( scalar @warnings, 1, "$dier: one warning" );
    like( $warnings[0], qr/died in plugin_llm_call_failed: (?:a?sync) hook exploded/, "$dier: names the hook" );

    my $f = $chat->simple_chat_f('boom');
    $f->await;
    like( ( $f->failure )[0], qr/request failed: 500/, "$dier: async keeps the original failure" );
  }
};

# A plugin hears of each call once: an earlier plugin whose after-hook
# finished is not told of a failure a later plugin's after-hook causes.
subtest 'a dying after-hook: only plugins whose after-hook did not finish hear of it' => sub {
  my %run = (
    simple_chat                   => sub { $_[0]->simple_chat('hi') },
    simple_chat_f                 => sub { $_[0]->simple_chat_f('hi')->get },
    simple_chat_stream            => sub { $_[0]->simple_chat_stream( sub { }, 'hi' ) },
    simple_chat_stream_realtime_f => sub { $_[0]->simple_chat_stream_realtime_f( undef, 'hi' )->get },
    simple_chat_with_tools        => sub { $_[0]->simple_chat_with_tools('hi') },
    simple_chat_with_tools_f      => sub { $_[0]->simple_chat_with_tools_f('hi')->get },
  );
  for my $method ( sort keys %run ) {
    my ( $chat, $before, $bomb, $after ) =
      chat( '+Test::Recorder', '+Test::Bomb', '+Test::Recorder' );
    ok( !eval { $run{$method}->($chat); 1 }, "$method: dies" );
    like( $@, qr/\Aafter-hook bomb/, "$method: with the after-hook's error" );
    is( scalar @{ $before->afters }, 1, "$method: the earlier plugin's after-hook ran" );
    is( scalar @{ $before->failed }, 0, "$method: ... and it is not told of a failure" );
    is( scalar @{ $bomb->failed }, 1, "$method: the dying plugin hears of it" );
    is( scalar @{ $after->failed }, 1, "$method: the later plugin hears of it" );
    is( scalar @{ $after->afters }, 0, "$method: ... and got no after-hook" );
  }
};

subtest 'Langfuse before a dying after-hook records one generation' => sub {
  require Langertha::Plugin::Langfuse;
  my $chat = Langertha::Chat->new( engine => engine(),
    plugins => [ Langfuse => { public_key => 'pk', secret_key => 'sk' }, '+Test::Bomb' ] );
  my ($lf) = @{ $chat->plugin_instances };
  ok( !eval { $chat->simple_chat('hi'); 1 }, 'dies' );
  my @generations = grep { $_->{type} eq 'generation-create' } @{ $lf->_batch };
  is( scalar @generations, 1, 'one generation for the one call' );
  ok( !defined $generations[0]{body}{level} || $generations[0]{body}{level} ne 'ERROR',
    '... the one its after-hook recorded' );

  # Called directly, without the host's bookkeeping: a failure report for
  # a call already recorded adds nothing.
  $lf->_batch([]);
  $lf->plugin_before_llm_call( [ { role => 'user', content => 'hi' } ], 1 )->get;
  $lf->plugin_after_llm_response( Langertha::Response->new( content => 'x' ), 1 )->get;
  $lf->plugin_llm_call_failed( "late\n", 1, {} )->get;
  @generations = grep { $_->{type} eq 'generation-create' } @{ $lf->_batch };
  is( scalar @generations, 1, 'a failure after the after-hook adds no generation' );
};

subtest 'a failure hook returning a cancelled Future does not hang the error' => sub {
  my ( $chat, $cancel, $rec ) = chat( '+Test::Cancelled', '+Test::Recorder' );
  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  ok( !eval { $chat->simple_chat('boom'); 1 }, 'sync: dies' );
  is( "$@", error_without_plugins( simple_chat => 'boom' ), 'sync: with the original error' );
  is( scalar @{ $rec->failed }, 1, 'sync: the next plugin still heard of it' );

  my $f = $chat->simple_chat_f('boom');
  ok( $f->is_ready, 'async: settled' );
  ok( $f->is_failed, 'async: failed, not cancelled' );
  like( ( $f->failure )[0], qr/request failed: 500/, 'async: the original failure' );
  is( scalar @{ $rec->failed }, 2, 'async: the next plugin still heard of it' );

  $cancel->pending(1);
  my $g = $chat->simple_chat_f('boom');
  ok( !$g->is_ready, 'async: waits for the pending failure hook' );
  $cancel->futures->[-1]->cancel;
  ok( $g->is_ready, 'async: settled once that hook was cancelled' );
  ok( $g->is_failed, '... failed, not cancelled' );
  like( ( $g->failure )[0], qr/request failed: 500/, '... with the original failure' );
  is( scalar @{ $rec->failed }, 3, '... after the next plugin heard of it' );
  is( scalar @warnings, 0, 'a cancel is not warned about' );
};

subtest 'sync: a failure hook returning a pending plain Future is not waited for' => sub {
  my ( $chat, $cancel, $rec ) = chat( '+Test::Cancelled', '+Test::Recorder' );
  $cancel->pending(1);
  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  ok( !eval { $chat->simple_chat('boom'); 1 }, 'dies' );
  is( "$@", error_without_plugins( simple_chat => 'boom' ), 'with the original error, not the Future\'s' );
  is( scalar @{ $rec->failed }, 1, 'the next plugin still heard of it' );
  ok( !$cancel->futures->[-1]->is_ready, 'the hook\'s Future is left pending' );
  is( scalar @warnings, 1, 'one warning' );
  like( $warnings[0], qr/\ATest::Cancelled returned a pending Future from plugin_llm_call_failed on a synchronous call/,
    'naming the plugin and the hook' );
};

# A 200 whose body reports an error, in the tool loops: the after-hooks get
# the body and finish, then the loop croaks reading it. That croak is not
# reported to any plugin as a failed call.
{
  package Test::BodyErrorEngine;
  use Moose;
  extends 'Langertha::Engine::Virtual';
  around virtual_reply => sub {
    my ( $orig, $self, $method, $path, $content ) = @_;
    my $reply = $self->$orig( $method, $path, $content );
    return $reply unless $reply->{code} == 200 && $content =~ /body error/;
    return { code => 200, message => 'OK',
      content => { error => { message => 'upstream overloaded', code => 502 } } };
  };
  __PACKAGE__->meta->make_immutable;
}

subtest 'tool loops: an error in a 200 body is not a failed call for the plugins' => sub {
  my %run = (
    simple_chat_with_tools   => sub { $_[0]->simple_chat_with_tools('body error') },
    simple_chat_with_tools_f => sub { $_[0]->simple_chat_with_tools_f('body error')->get },
  );
  for my $method ( sort keys %run ) {
    my $chat = Langertha::Chat->new(
      engine      => Test::BodyErrorEngine->new( langfuse_enabled => 0, fallback => answer('unused') ),
      mcp_servers => [$mcp],
      plugins     => [ '+Test::Recorder', '+Test::Recorder' ],
    );
    my @rec = @{ $chat->plugin_instances };
    ok( !eval { $run{$method}->($chat); 1 }, "$method: dies" );
    like( $@, qr/response carried an error: upstream overloaded/, "$method: with the body's error" );
    for my $i ( 0 .. $#rec ) {
      is( scalar @{ $rec[$i]->afters }, 1, "$method: plugin $i: the after-hook ran" );
      is_deeply( $rec[$i]->afters->[0][0], { error => { message => 'upstream overloaded', code => 502 } },
        "$method: plugin $i: ... on the error body" );
      is( scalar @{ $rec[$i]->failed }, 0, "$method: plugin $i: no plugin_llm_call_failed" );
    }
  }
};

subtest 'a plugin without the hook (the base class default) changes nothing' => sub {
  my ($chat) = chat('+Langertha::Plugin');
  ok( !eval { $chat->simple_chat('boom'); 1 }, 'dies' );
  is( "$@", error_without_plugins( simple_chat => 'boom' ), 'unchanged' );
};

done_testing;
