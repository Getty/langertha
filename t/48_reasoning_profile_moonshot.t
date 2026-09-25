#!/usr/bin/env perl
# ABSTRACT: Moonshot kimi-k3 takes reasoning_effort low|high|max; K2.x takes none (karr k207)

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;

use Langertha::Engine::Moonshot;
use Langertha::Engine::MoonshotAnthropic;
use Langertha::Reasoning::Profile;

# karr k207 / ADRs 0019, 0023: Moonshot cleared reasoning_effort engine-wide, so
# an explicit effort on kimi-k3 was dropped silently although K3 documents a
# top-level reasoning_effort (low|high|max, default max, always reasons) on
# chat/completions and output_config.effort with the same enum and NO thinking
# request field on the Messages API. The K2.x line takes no effort at all
# (thinking object only). So the flag is cleared per model (layer 3, the first
# per-model clear of reasoning_effort), and a kimi-k3 Profile row drops the
# levels K3 does not take. Advisor 2026-09-25, from Moonshot's documentation,
# not live-verified.

my $json = JSON::MaybeXS->new->canonical(1);
my @MSG  = ( [ { role => 'user', content => 'hi' } ] );

sub body {
  my ( $class, %args ) = @_;
  my $controls = delete $args{controls} // {};
  my $engine = $class->new( api_key => 'k', %args );
  return $json->decode( $engine->chat_request( @MSG, controls => $controls )->content );
}

my %K3_OK = map { $_ => 1 } qw( low high max );

# --- OpenAI face (chat/completions) ---
ok( Langertha::Engine::Moonshot->new( api_key => 'k' )->supports('reasoning_effort'),
  'Moonshot kimi-k3 (default) advertises reasoning_effort' );
# kimi-k2-thinking: a dash-form K2 id is K2 too (thinking object only).
for my $model (qw( kimi-k2.6 kimi-k2.7-code kimi-k2.7-code-highspeed kimi-k2-thinking )) {
  my $engine = Langertha::Engine::Moonshot->new( api_key => 'k', model => $model );
  ok( !$engine->supports('reasoning_effort'), "Moonshot $model: reasoning_effort cleared (layer 3)" );
  ok( !$engine->supports('tool_choice_any'), "Moonshot $model: tool_choice_any still cleared" );
  is_deeply( [ $engine->reasoning_kwargs_for( reasoning_effort => 'high' ) ], [],
    "Moonshot $model: the k204 gate sends no reasoning field" );
  ok( !exists body( 'Langertha::Engine::Moonshot', model => $model, reasoning_effort => 'high' )
      ->{reasoning_effort}, "Moonshot $model: no reasoning_effort on the wire" );
}

is_deeply( body( 'Langertha::Engine::Moonshot', model => 'kimi-k3', reasoning_effort => 'high' ),
  { model => 'kimi-k3', reasoning_effort => 'high', stream => JSON::MaybeXS::false(),
    max_tokens => 4096, messages => $MSG[0] },
  'kimi-k3 wire: top-level reasoning_effort high' );

for my $effort (qw( none minimal low medium high xhigh max )) {
  my $got = body( 'Langertha::Engine::Moonshot', reasoning_effort => $effort )->{reasoning_effort};
  is( $got, $K3_OK{$effort} ? $effort : undef,
    "Moonshot kimi-k3 '$effort': " . ( $K3_OK{$effort} ? 'sent' : 'dropped, server default max applies' ) );
}
is( body( 'Langertha::Engine::Moonshot', controls => { reasoning_effort => 'low' } )->{reasoning_effort},
  'low', 'Moonshot kimi-k3: a per-request control reaches the wire' );

# --- Anthropic face (/anthropic/v1/messages) ---
for my $effort (qw( none minimal low medium high xhigh max )) {
  my $got = body( 'Langertha::Engine::MoonshotAnthropic', reasoning_effort => $effort );
  is_deeply( $got->{output_config}, $K3_OK{$effort} ? { effort => $effort } : undef,
    "MoonshotAnthropic kimi-k3 '$effort': output_config.effort "
      . ( $K3_OK{$effort} ? 'sent' : 'dropped' ) );
  ok( !exists $got->{thinking}, "MoonshotAnthropic kimi-k3 '$effort': no thinking field" );
}
ok( !exists body( 'Langertha::Engine::MoonshotAnthropic', thinking_display => 'summarized' )->{thinking},
  'MoonshotAnthropic kimi-k3: thinking_display does not add a thinking field' );

my $profile = Langertha::Reasoning::Profile->for_model('kimi-k3');
is_deeply( $profile->levels, [qw( low high max )], 'kimi-k3 profile: low|high|max' );
ok( !$profile->can_disable, 'kimi-k3 profile: reasoning cannot be disabled' );
is( $profile->disable_form, 'absent', 'kimi-k3 profile: off is the absent field' );

# The k196 multi-digit guard: kimi-k30 is an unknown id, while a suffixed or
# dotted K3 id stays in the family.
is( Langertha::Reasoning::Profile->for_model('kimi-k30'),
  Langertha::Reasoning::Profile->for_model(''), 'kimi-k30: unknown id, provider default' );
for my $id (qw( kimi-k3-turbo kimi-k3.5 )) {
  is_deeply( Langertha::Reasoning::Profile->for_model($id)->levels, [qw( low high max )],
    "$id: kimi-k3 family" );
}

done_testing;
