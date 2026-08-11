#!/usr/bin/env perl
# ABSTRACT: Locks current usage-handling behaviour across wire families
#
# karr #28g regression gate. Locks (does not aspirationally fix) every
# shape that Langertha::Response currently exposes for token usage:
#
#   * raw `usage` hash is provider-verbatim on some engines, normalised
#     away on others (Gemini, Ollama, OpenAIResponses). The contract is
#     "accessors normalise; raw hash is engine-defined" — locked below.
#   * `prompt_tokens` / `completion_tokens` / `total_tokens` read across
#     all wire shapes consistently. `total_tokens` derives when the
#     provider omits it.
#   * cache-token keys survive on Anthropic (verbatim) but `cached_tokens`
#     is LOST on OpenAIResponses (normalisation strips
#     `input_tokens_details`). Documented as a gap.
#   * Langertha::Usage / Pricing / Cost roundtrip arithmetically.
#   * Langertha::Pricing ships an empty `rules` table by design —
#     pricing is caller-supplied, no auto-fetch, determinism.

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;
use HTTP::Response;
use Path::Tiny qw( path );

use Langertha::Response;
use Langertha::Usage;
use Langertha::Pricing;
use Langertha::Cost;

use Langertha::Engine::OpenAI;
use Langertha::Engine::Anthropic;
use Langertha::Engine::Gemini;
use Langertha::Engine::Ollama;
use Langertha::Engine::OpenAIResponses;

my $json = JSON::MaybeXS->new->canonical(1)->utf8(1);

# -------------------------------------------------------------------------
# Helpers — build canned HTTP::Response bodies the same way t/70_response.t
# does, so no new mocking layer is introduced.
# -------------------------------------------------------------------------

sub mock_http {
    my ($body_hash) = @_;
    my $http = HTTP::Response->new(200, 'OK');
    $http->content($json->encode($body_hash));
    $http->header('Content-Type' => 'application/json');
    return $http;
}

# =========================================================================
# 1. Raw usage passthrough per wire family
# =========================================================================
#
# Each subtest feeds a canned provider body through the real engine
# chat_response path and asserts what the resulting Response->usage hash
# looks like. Three behavioural classes are locked:
#
#   * verbatim passthrough: OpenAI, Anthropic
#   * camelCase → snake_case translation: Gemini
#   * engine-key translation: Ollama, OpenAIResponses
#
# Engines that translate lose the original key set in usage. Engines
# that pass through carry every provider field (incl. cache tokens).

subtest 'OpenAI: usage passed verbatim' => sub {
    my $openai = Langertha::Engine::OpenAI->new(
        api_key => 'testkey',
        model   => 'gpt-4o-mini',
    );
    my $http = mock_http({
        id      => 'chatcmpl-1',
        model   => 'gpt-4o-mini',
        choices => [{ message => { role => 'assistant', content => 'hi' }, finish_reason => 'stop' }],
        usage   => {
            prompt_tokens     => 100,
            completion_tokens => 50,
            total_tokens      => 150,
            # OpenAI chat completions does not currently emit cache tokens,
            # but a nested detail block would survive verbatim if it did:
            prompt_tokens_details => { cached_tokens => 0 },
        },
    });

    my $resp = $openai->chat_response($http);
    ok($resp->has_usage, 'usage present');
    is($resp->usage->{prompt_tokens},     100, 'raw prompt_tokens survives');
    is($resp->usage->{completion_tokens}, 50,  'raw completion_tokens survives');
    is($resp->usage->{total_tokens},      150, 'raw total_tokens survives');
    is($resp->usage->{prompt_tokens_details}{cached_tokens}, 0,
        'raw prompt_tokens_details survives (verbatim passthrough)');
};

subtest 'Anthropic: usage passed verbatim, incl. cache tokens' => sub {
    my $anthropic = Langertha::Engine::Anthropic->new(
        api_key => 'testkey',
        model   => 'claude-sonnet-4-6',
    );
    my $http = mock_http({
        id          => 'msg_1',
        model       => 'claude-sonnet-4-6',
        stop_reason => 'end_turn',
        content     => [{ type => 'text', text => 'hi' }],
        usage       => {
            input_tokens                  => 200,
            output_tokens                 => 80,
            cache_creation_input_tokens   => 1024,
            cache_read_input_tokens       => 4096,
        },
    });

    my $resp = $anthropic->chat_response($http);
    ok($resp->has_usage, 'usage present');
    is($resp->usage->{input_tokens},                200,  'raw input_tokens survives');
    is($resp->usage->{output_tokens},               80,   'raw output_tokens survives');
    is($resp->usage->{cache_creation_input_tokens}, 1024, 'cache_creation_input_tokens survives verbatim');
    is($resp->usage->{cache_read_input_tokens},     4096, 'cache_read_input_tokens survives verbatim');
};

subtest 'Gemini: usageMetadata camelCase → snake_case translation' => sub {
    my $gemini = Langertha::Engine::Gemini->new(
        api_key => 'testkey',
        model   => 'gemini-2.5-flash',
    );
    my $http = mock_http({
        candidates => [{
            content      => { parts => [{ text => 'hi' }], role => 'model' },
            finishReason => 'STOP',
        }],
        usageMetadata => {
            promptTokenCount     => 300,
            candidatesTokenCount => 120,
            totalTokenCount      => 420,
        },
        modelVersion => 'gemini-2.5-flash',
    });

    my $resp = $gemini->chat_response($http);
    ok($resp->has_usage, 'usage present');
    is($resp->usage->{prompt_tokens},     300, 'promptTokenCount → prompt_tokens');
    is($resp->usage->{completion_tokens}, 120, 'candidatesTokenCount → completion_tokens');
    is($resp->usage->{total_tokens},      420, 'totalTokenCount → total_tokens');
    ok(!exists $resp->usage->{promptTokenCount},
        'raw camelCase promptTokenCount is GONE (normalised away)');
    ok(!exists $resp->usage->{candidatesTokenCount},
        'raw camelCase candidatesTokenCount is GONE (normalised away)');
    ok(!exists $resp->usage->{totalTokenCount},
        'raw camelCase totalTokenCount is GONE (normalised away)');
};

subtest 'Ollama: prompt_eval_count/eval_count → prompt_tokens/completion_tokens' => sub {
    my $ollama = Langertha::Engine::Ollama->new(
        url   => 'http://test.invalid:11434',
        model => 'llama3.3',
    );
    my $http = mock_http({
        model      => 'llama3.3',
        message    => { role => 'assistant', content => 'hi' },
        done       => JSON->true,
        done_reason => 'stop',
        prompt_eval_count => 400,
        eval_count        => 160,
    });

    my $resp = $ollama->chat_response($http);
    ok($resp->has_usage, 'usage present');
    is($resp->usage->{prompt_tokens},     400, 'prompt_eval_count → prompt_tokens');
    is($resp->usage->{completion_tokens}, 160, 'eval_count → completion_tokens');
    ok(!exists $resp->usage->{prompt_eval_count},
        'raw prompt_eval_count is GONE (normalised away)');
    ok(!exists $resp->usage->{eval_count},
        'raw eval_count is GONE (normalised away)');
    ok(!exists $resp->usage->{total_tokens},
        'Ollama does not synthesise total_tokens in usage');
};

subtest 'OpenAIResponses: normalises to chat-style, LOSES cached_tokens' => sub {
    # Reads t/data/responses_api_text.json — same fixture t/60_responses_requests.t
    # uses. Locks the gap that the OpenAIResponses engine strips
    # `input_tokens_details.cached_tokens` during normalisation.
    my $fixture = $json->decode(
        path('t/data/responses_api_text.json')->slurp
    );

    my $engine = Langertha::Engine::OpenAIResponses->new(
        api_key => 'testkey',
        model   => 'gpt-5.5-pro',
    );
    my $resp = $engine->chat_response( mock_http($fixture) );

    ok($resp->has_usage, 'usage present');
    is($resp->usage->{prompt_tokens},     25, 'input_tokens → prompt_tokens');
    is($resp->usage->{completion_tokens}, 42, 'output_tokens → completion_tokens');
    is($resp->usage->{total_tokens},      67, 'total_tokens survives');
    is($resp->usage->{completion_tokens_details}{reasoning_tokens}, 18,
        'reasoning_tokens survives under completion_tokens_details');

    # GAP (documented): input_tokens_details.cached_tokens is DROPPED here.
    # The fixture has cached_tokens = 0; even at zero it should survive as
    # a key in the raw hash if the engine treated it verbatim — but
    # OpenAIResponses only projects prompt_tokens / completion_tokens /
    # total_tokens / completion_tokens_details into the usage hash, so
    # cache telemetry from the Responses API is invisible at the
    # Response->usage level. karr #28 tracks surfacing this.
    ok(!exists $resp->usage->{input_tokens_details},
        'input_tokens_details is DROPPED on OpenAIResponses (GAP, see karr #28)');
    ok(!exists $resp->usage->{cached_tokens},
        'cached_tokens is DROPPED on OpenAIResponses (GAP, see karr #28)');
};

# =========================================================================
# 2. Accessor normalisation
# =========================================================================
#
# The accessors prompt_tokens / completion_tokens / total_tokens are
# the cross-provider contract. The `usage` hash is engine-defined; the
# accessors are not. This subtest feeds every raw shape into a fresh
# Response and asserts all three accessors yield equivalent numbers,
# including total_tokens derived from prompt+completion when the
# provider omits it.

subtest 'accessor normalisation across raw shapes' => sub {
    my @shapes = (
        # [label, usage hash, expected_prompt, expected_completion, expected_total]
        [ 'OpenAI-style',    { prompt_tokens => 10, completion_tokens => 5, total_tokens => 15 },
            10, 5, 15 ],
        [ 'Anthropic-style', { input_tokens  => 10, output_tokens      => 5 },
            10, 5, 15 ],
        [ 'Anthropic + total', { input_tokens => 10, output_tokens => 5, total_tokens => 17 },
            10, 5, 17 ],   # total_tokens from usage wins over derived sum
        [ 'Gemini-style',    { prompt_tokens => 10, completion_tokens => 5, total_tokens => 15 },
            10, 5, 15 ],
        [ 'Ollama-style',    { prompt_tokens => 10, completion_tokens => 5 },
            10, 5, 15 ],    # total derived (provider does not emit total_tokens)
        [ 'Responses-style', { prompt_tokens => 10, completion_tokens => 5, total_tokens => 15 },
            10, 5, 15 ],
    );

    for my $row (@shapes) {
        my ($label, $usage, $ep, $ec, $et) = @$row;
        my $resp = Langertha::Response->new(content => 'x', usage => $usage);
        is($resp->prompt_tokens,     $ep, "$label prompt_tokens accessor");
        is($resp->completion_tokens, $ec, "$label completion_tokens accessor");
        is($resp->total_tokens,      $et, "$label total_tokens accessor (derived when provider omits)");
    }

    # No usage → all undef
    my $empty = Langertha::Response->new(content => 'x');
    is($empty->prompt_tokens,     undef, 'no usage → prompt_tokens undef');
    is($empty->completion_tokens, undef, 'no usage → completion_tokens undef');
    is($empty->total_tokens,      undef, 'no usage → total_tokens undef');
};

# =========================================================================
# 3. Cache tokens survive verbatim for the engines that pass usage through;
#    OpenAIResponses drops them — documented GAP.
# =========================================================================

subtest 'cache tokens: Anthropic survives verbatim' => sub {
    my $anthropic = Langertha::Engine::Anthropic->new(
        api_key => 'testkey',
        model   => 'claude-sonnet-4-6',
    );
    my $resp = $anthropic->chat_response(mock_http({
        id          => 'msg_cache',
        model       => 'claude-sonnet-4-6',
        stop_reason => 'end_turn',
        content     => [{ type => 'text', text => 'cached' }],
        usage       => {
            input_tokens                => 50,
            output_tokens               => 20,
            cache_creation_input_tokens => 2048,
            cache_read_input_tokens     => 8192,
        },
    }));
    is($resp->usage->{cache_creation_input_tokens}, 2048,
        'Anthropic cache_creation_input_tokens survives in usage');
    is($resp->usage->{cache_read_input_tokens},     8192,
        'Anthropic cache_read_input_tokens survives in usage');

    # GAP: Response.pm has no accessor for cache tokens. The canonical
    # `prompt_tokens` accessor ignores them. Callers today read
    # `$resp->usage->{cache_*}` directly. Until an accessor exists,
    # this is the documented contract — do NOT add a fake accessor here
    # to "fix" it (karr #18e: Response.usage cached_content_token_count
    # telemetry).
    is($resp->prompt_tokens, 50,
        'prompt_tokens accessor does NOT include cache tokens (by design — karr #18e)');
};

subtest 'cache tokens: OpenAIResponses DROPS them (documented GAP)' => sub {
    # Fixture contains cached_tokens = 0. Even when non-zero the engine
    # would drop it — see engine code path. Lock the inconsistency.
    my $fixture = $json->decode(
        path('t/data/responses_api_text.json')->slurp
    );
    my $engine = Langertha::Engine::OpenAIResponses->new(
        api_key => 'testkey',
        model   => 'gpt-5.5-pro',
    );
    my $resp = $engine->chat_response( mock_http($fixture) );

    ok(!exists $resp->usage->{input_tokens_details},
        'OpenAIResponses drops input_tokens_details (cached_tokens telemetry is invisible)');
};

# =========================================================================
# 4. Cost roundtrip: Usage -> Pricing -> Cost -> to_hash
# =========================================================================

subtest 'cost roundtrip: known rule' => sub {
    my $pricing = Langertha::Pricing->new(
        rules => {
            'gpt-4o-mini' => { input_per_million => 0.15, output_per_million => 0.60 },
        },
    );
    my $usage = Langertha::Usage->from_hash(
        { prompt_tokens => 30, completion_tokens => 70 }
    );
    is($usage->input_tokens,  30, 'from_hash maps prompt_tokens → input_tokens');
    is($usage->output_tokens, 70, 'from_hash maps completion_tokens → output_tokens');

    my $cost = $pricing->cost_for($usage, 'gpt-4o-mini');
    isa_ok($cost, 'Langertha::Cost');

    # (30 / 1_000_000) * 0.15 = 0.0000045
    # (70 / 1_000_000) * 0.60 = 0.0000420
    is($cost->input_usd  + 0, 0.0000045, 'input_usd arithmetic (30 tokens at $0.15/M)');
    is($cost->output_usd + 0, 0.0000420, 'output_usd arithmetic (70 tokens at $0.60/M)');
    is($cost->total_usd  + 0, 0.0000465, 'total_usd = input + output');

    my $h = $cost->to_hash;
    is($h->{input_cost_usd} + 0,  0.0000045, 'to_hash input_cost_usd');
    is($h->{output_cost_usd} + 0, 0.0000420, 'to_hash output_cost_usd');
    is($h->{total_cost_usd} + 0,  0.0000465, 'to_hash total_cost_usd');
    is($h->{currency}, 'USD', 'to_hash currency defaults to USD');
};

subtest 'cost roundtrip: unknown model falls back to default_rule' => sub {
    my $pricing = Langertha::Pricing->new(
        default_rule => { input_per_million => 1, output_per_million => 2 },
    );
    my $usage = Langertha::Usage->new(input_tokens => 1_000_000, output_tokens => 500_000);
    my $cost  = $pricing->cost_for($usage, 'never-seen-model-xyz');
    is($cost->input_usd  + 0, 1.00, 'default_rule applied for unknown model — input');
    is($cost->output_usd + 0, 1.00, 'default_rule applied for unknown model — output (500k * $2/M)');
    is($cost->total_usd  + 0, 2.00, 'default_rule total');
};

subtest 'cost roundtrip: no rule, no default → zero cost' => sub {
    my $pricing = Langertha::Pricing->new;
    my $usage   = Langertha::Usage->new(input_tokens => 5_000_000, output_tokens => 1_000_000);
    my $cost    = $pricing->cost_for($usage, 'whatever');
    is($cost->input_usd  + 0, 0, 'no rule, no default → input_usd = 0');
    is($cost->output_usd + 0, 0, 'no rule, no default → output_usd = 0');
    is($cost->total_usd  + 0, 0, 'no rule, no default → total_usd = 0');
};

# =========================================================================
# 5. Pricing invariant: rules table is empty by design
# =========================================================================
#
# Langertha::Pricing ships with an empty `rules` table — all pricing is
# caller-supplied. This is intentional: no auto-fetch, no hidden
# provider constants, deterministic across runs. A future PR that
# hardcodes provider prices in lib/Langertha/Engine/*.pm or seeds
# Pricing with a static catalog will trip this test.

subtest 'Pricing invariant: empty rules by design' => sub {
    my $p = Langertha::Pricing->new;
    is_deeply($p->rules, {}, 'default Pricing->rules is an empty hashref');

    # rule_for(unknown) returns the default_rule (undef here) — there is
    # no implicit "well-known model" table to fall through to.
    is($p->rule_for('gpt-4o-mini'),     undef, 'no implicit rule for gpt-4o-mini');
    is($p->rule_for('claude-sonnet-4-6'), undef, 'no implicit rule for claude-sonnet-4-6');
    is($p->rule_for('gemini-2.5-flash'),  undef, 'no implicit rule for gemini-2.5-flash');

    # Cost for any model with no rule, no default is zero — never an
    # exception, never a guessed price.
    my $cost = $p->cost_for(
        Langertha::Usage->new(input_tokens => 1, output_tokens => 1),
        'any-model'
    );
    is($cost->total_usd + 0, 0, 'unknown model + no default → zero cost (no exception)');
};

done_testing;