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

# --- karr k215: MoonshotAnthropic on K2.x ---
# Kimi's Messages API documents output_config.effort for kimi-k3 only; on K2.x it
# parses thinking.type (Claude Code guide): kimi-k2.7-code accepts only
# `enabled` ("400 invalid thinking: only type=enabled is allowed"), kimi-k2.6
# takes enabled|disabled. `adaptive` is undocumented for Kimi. So K2 gets the
# thinking toggle and never an effort: k2.6 none -> disabled, any level ->
# enabled; k2.7-code any level -> enabled, none omitted (it cannot disable).
# Whether `enabled` needs budget_tokens there is UNVERIFIED -- none is sent.
# Advisor 2026-09-25, documentation only, no live call.
my %TOGGLE = (
  'kimi-k2.6'                => 1,
  'kimi-k2.7-code'           => 0,
  'kimi-k2.7-code-highspeed' => 0,
);
for my $model ( sort keys %TOGGLE ) {
  my $can_off = $TOGGLE{$model};
  ok( Langertha::Engine::MoonshotAnthropic->new( api_key => 'k', model => $model )
      ->supports('reasoning_effort'), "MoonshotAnthropic $model: reasoning_effort (the toggle) advertised" );
  for my $builder (qw( chat_request chat_stream_request )) {
    for my $effort (qw( none minimal low medium high xhigh max )) {
      my $engine = Langertha::Engine::MoonshotAnthropic->new(
        api_key => 'k', model => $model, reasoning_effort => $effort );
      my $got = $json->decode( $engine->$builder( @MSG, controls => {} )->content );
      my $want = $effort ne 'none' ? { type => 'enabled' }
               : $can_off          ? { type => 'disabled' }
               :                     undef;
      ok( !exists $got->{output_config}, "MoonshotAnthropic $model $builder '$effort': no output_config" );
      is_deeply( $got->{thinking}, $want, "MoonshotAnthropic $model $builder '$effort': thinking "
        . ( $want ? $want->{type} : 'absent' ) );
      ok( !exists $got->{temperature}, "MoonshotAnthropic $model $builder '$effort': no temperature" );
    }
  }
  ok( !exists body( 'Langertha::Engine::MoonshotAnthropic', model => $model )->{thinking},
    "MoonshotAnthropic $model: no reasoning control, no thinking field" );
  is_deeply( body( 'Langertha::Engine::MoonshotAnthropic', model => $model,
      controls => { reasoning_effort => 'high' } )->{thinking},
    { type => 'enabled' }, "MoonshotAnthropic $model: a per-request control reaches the wire" );
}

# K2 ids outside the documented pair (sunset kimi-k2.5, dash-form kimi-k2-thinking)
# take no effort on this face and have no documented toggle: nothing is sent.
for my $model (qw( kimi-k2.5 kimi-k2-thinking )) {
  my $engine = Langertha::Engine::MoonshotAnthropic->new( api_key => 'k', model => $model );
  ok( !$engine->supports('reasoning_effort'), "MoonshotAnthropic $model: reasoning_effort cleared" );
  my $got = body( 'Langertha::Engine::MoonshotAnthropic', model => $model, reasoning_effort => 'high' );
  ok( !exists $got->{output_config} && !exists $got->{thinking}, "MoonshotAnthropic $model: no reasoning field" );
}

# The toggle rows are anchored on Kimi's own ids: AKI.IO's hosted
# kimi-k2.7-code-1100b is not Kimi's API and keeps its previous wire.
ok( !Langertha::Reasoning::Profile->for_model('kimi-k2.7-code-1100b')->has_thinking_on,
  'kimi-k2.7-code-1100b (AKI.IO): no Kimi toggle row' );
my $p26 = Langertha::Reasoning::Profile->for_model('kimi-k2.6');
is( $p26->thinking_on, 'enabled', 'kimi-k2.6 profile: on is thinking {type: enabled}' );
is( $p26->disable_form, 'thinking_disabled', 'kimi-k2.6 profile: off is thinking {type: disabled}' );
ok( !Langertha::Reasoning::Profile->for_model('kimi-k2.7-code')->can_disable,
  'kimi-k2.7-code profile: cannot disable' );

# The chat face is unchanged: Engine::Moonshot still clears reasoning_effort on
# K2, so the shared rows send nothing there (a chat-face toggle is future work).
ok( !exists body( 'Langertha::Engine::Moonshot', model => 'kimi-k2.6', reasoning_effort => 'none' )->{thinking},
  'Moonshot kimi-k2.6: still no thinking field on chat/completions' );

done_testing;
