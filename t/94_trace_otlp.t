#!/usr/bin/env perl
# ABSTRACT: Langertha::Trace::OTLP payload shape (OTLP/HTTP JSON) and the gen_ai.* mapping, no network

use strict;
use warnings;

use Test2::Bundle::More;
use JSON::MaybeXS;

use Langertha::Trace::OTLP;
use Langertha::Usage;
use Langertha::Response;
use Langertha::CallResult;
use Langertha::Engine::OpenAI;

my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );
my $OTLP = 'Langertha::Trace::OTLP';

my $trace = 'ab' x 16;
my $span  = 'cd' x 8;

sub payload_of {
  my ( $records, %new ) = @_;
  my $otlp = $OTLP->new(%new);
  return $json->decode( $otlp->to_json($records) );
}

sub spans_of { $_[0]{resourceSpans}[0]{scopeSpans}[0]{spans} }

sub attrs_of {
  my ($span_data) = @_;
  return { map { $_->{key} => $_->{value} } @{ $span_data->{attributes} } };
}

sub resource_of {
  my ($payload) = @_;
  return { map { $_->{key} => $_->{value} } @{ $payload->{resourceSpans}[0]{resource}{attributes} } };
}

sub rec {
  return { trace_id => $trace, span_id => $span, name => 'chat m', kind => 'client',
    start => 1700000000.123456, end => 1700000001.5, @_ };
}

subtest 'envelope: resource, scope, schemaUrl' => sub {
  my $p = payload_of( [ rec() ] );
  is_deeply( [ keys %$p ], ['resourceSpans'], 'one top-level key' );
  is_deeply( scalar @{ $p->{resourceSpans} }, 1, 'one resource' );
  my $rs = $p->{resourceSpans}[0];
  is_deeply( scalar @{ $rs->{scopeSpans} }, 1, 'one scope' );
  my $scope = $rs->{scopeSpans}[0];
  is_deeply( $scope->{schemaUrl}, 'https://opentelemetry.io/schemas/1.41.1', 'schemaUrl pinned to 1.41.1' );
  is_deeply( $scope->{scope}{name}, 'langertha', 'default scope name' );
  ok( length $scope->{scope}{version}, 'scope version present' );
  is_deeply( $OTLP->SEMCONV_VERSION, '1.41.1', 'SEMCONV_VERSION' );
  is_deeply( $OTLP->SCHEMA_URL, 'https://opentelemetry.io/schemas/1.41.1', 'SCHEMA_URL' );
  is_deeply( resource_of($p)->{'service.name'}, { stringValue => 'unknown_service:perl' }, 'default service.name' );

  my $named = payload_of( [ rec() ], service_name => 'svc', scope_name => 'sc', scope_version => '9.9',
    resource_attributes => { 'service.version' => '1.0', 'deployment.environment.name' => 'test' } );
  my $res = resource_of($named);
  is_deeply( $res->{'service.name'}, { stringValue => 'svc' }, 'service_name' );
  is_deeply( $res->{'service.version'}, { stringValue => '1.0' }, 'resource attribute' );
  is_deeply( $res->{'deployment.environment.name'}, { stringValue => 'test' }, 'second resource attribute' );
  is_deeply( $named->{resourceSpans}[0]{scopeSpans}[0]{scope}, { name => 'sc', version => '9.9' }, 'scope name and version' );

  my $via_attr = payload_of( [ rec() ], resource_attributes => { 'service.name' => 'from-attrs' } );
  is_deeply( resource_of($via_attr)->{'service.name'}, { stringValue => 'from-attrs' },
    'service.name taken from resource_attributes' );

  my $both = payload_of( [ rec() ], service_name => 'explicit', resource_attributes => { 'service.name' => 'x' } );
  is_deeply( resource_of($both)->{'service.name'}, { stringValue => 'explicit' }, 'service_name wins' );
};

subtest 'span: ids, kind, times, status' => sub {
  my $p = payload_of( [ rec( trace_id => uc $trace, span_id => uc $span ) ] );
  my ($s) = @{ spans_of($p) };
  like( $s->{traceId}, qr/\A[0-9a-f]{32}\z/, 'traceId is 32 lowercase hex' );
  like( $s->{spanId},  qr/\A[0-9a-f]{16}\z/, 'spanId is 16 lowercase hex' );
  is_deeply( $s->{traceId}, $trace, 'uppercase input lowercased' );
  ok( !exists $s->{parentSpanId}, 'parentSpanId absent on a root' );
  is_deeply( $s->{name}, 'chat m', 'name' );
  is_deeply( $s->{kind}, 3, 'client kind is integer 3' );
  ok( !exists $s->{status}, 'status unset by default' );

  my %kinds = ( internal => 1, server => 2, client => 3, producer => 4, consumer => 5 );
  for my $name ( sort keys %kinds ) {
    my ($k) = @{ spans_of( payload_of( [ rec( kind => $name ) ] ) ) };
    is_deeply( $k->{kind}, $kinds{$name}, "kind $name" );
  }
  my $no_kind = rec();
  delete $no_kind->{kind};
  my ($default_kind) = @{ spans_of( payload_of( [$no_kind] ) ) };
  is_deeply( $default_kind->{kind}, 1, 'kind defaults to internal' );

  my ($child) = @{ spans_of( payload_of( [ rec( parent_span_id => 'EF' x 8 ) ] ) ) };
  is_deeply( $child->{parentSpanId}, 'ef' x 8, 'parentSpanId lowercase when given' );
  my ($empty_parent) = @{ spans_of( payload_of( [ rec( parent_span_id => '' ) ] ) ) };
  ok( !exists $empty_parent->{parentSpanId}, 'empty parent id counts as root' );

  my $raw = $OTLP->new->to_json( [ rec() ] );
  like( $raw, qr/"startTimeUnixNano":"1700000000123456000"/, 'start as decimal string, microsecond precision' );
  like( $raw, qr/"endTimeUnixNano":"1700000001500000000"/, 'end as decimal string' );
  is_deeply( $s->{startTimeUnixNano}, '1700000000123456000', 'start nanos' );
  is_deeply( $s->{endTimeUnixNano},   '1700000001500000000', 'end nanos' );
  my ($whole) = @{ spans_of( payload_of( [ rec( start => 1700000000, end => 1700000000 ) ] ) ) };
  is_deeply( $whole->{startTimeUnixNano}, '1700000000000000000', 'whole seconds padded to 19 digits' );
  my ($no_end) = @{ spans_of( payload_of( [ rec( end => undef ) ] ) ) };
  is_deeply( $no_end->{endTimeUnixNano}, $no_end->{startTimeUnixNano}, 'end defaults to start' );
  my ($carry) = @{ spans_of( payload_of( [ rec( start => 1700000000.9999999 ) ] ) ) };
  is_deeply( $carry->{startTimeUnixNano}, '1700000001000000000', 'rounding carries into the next second' );

  my ($err) = @{ spans_of( payload_of( [ rec( status => { code => 'error', message => 'boom' } ) ] ) ) };
  is_deeply( $err->{status}, { code => 2, message => 'boom' }, 'error status code 2 (integer) with message' );
  my ($err_nomsg) = @{ spans_of( payload_of( [ rec( status => { code => 'error' } ) ] ) ) };
  is_deeply( $err_nomsg->{status}, { code => 2 }, 'error status without message' );
  my ($ok) = @{ spans_of( payload_of( [ rec( status => { code => 'ok' } ) ] ) ) };
  is_deeply( $ok->{status}{code}, 1, 'explicit ok is code 1' );

  my ($ev) = @{ spans_of( payload_of( [ rec( events => [ { name => 'e', time => 1700000000.5,
    attributes => { k => 'v' } } ] ) ] ) ) };
  is_deeply( $ev->{events}[0]{name}, 'e', 'event name' );
  is_deeply( $ev->{events}[0]{timeUnixNano}, '1700000000500000000', 'event time nanos string' );
  is_deeply( $ev->{events}[0]{attributes}, [ { key => 'k', value => { stringValue => 'v' } } ], 'event attributes' );
  ok( !exists $s->{events}, 'no events key without events' );
};

subtest 'span record validation croaks' => sub {
  my $otlp = $OTLP->new;
  for my $case (
    [ 'short trace id'  => rec( trace_id => 'abc' ) ],
    [ 'non-hex span id' => rec( span_id => 'zz' x 8 ) ],
    [ 'short parent id' => rec( parent_span_id => 'ab' ) ],
    [ 'unknown kind'    => rec( kind => 'bogus' ) ],
    [ 'unknown status'  => rec( status => { code => 'meh' } ) ],
    [ 'no start'        => rec( start => undef ) ],
    [ 'no name'         => rec( name => undef ) ],
    [ 'negative time'   => rec( start => -1 ) ],
    [ 'text time'       => rec( start => 'yesterday' ) ],
  ) {
    ok( !eval { $otlp->to_json( [ $case->[1] ] ); 1 }, "croaks: $case->[0]" );
  }
  ok( !eval { $otlp->build_payload('nope'); 1 }, 'build_payload needs an ArrayRef' );
};

subtest 'attribute types' => sub {
  my $true  = JSON::MaybeXS::true();
  my $false = JSON::MaybeXS::false();
  my ($s) = @{ spans_of( payload_of( [ rec( attributes => {
    'gen_ai.usage.input_tokens'  => 12,
    'gen_ai.usage.output_tokens' => '7',
    'gen_ai.request.max_tokens'  => 256,
    'gen_ai.request.seed'        => 42,
    'server.port'                => 8443,
    'gen_ai.request.temperature' => 0,
    'gen_ai.request.top_p'       => '0.9',
    'gen_ai.response.time_to_first_chunk' => 0.25,
    'gen_ai.request.stream'      => $true,
    'gen_ai.response.id'         => '1234567890',
    'gen_ai.response.model'      => '4',
    'gen_ai.request.model'       => '1e3',
    'plain.number'               => 5,
    'a.bool'                     => $false,
    'gen_ai.response.finish_reasons' => ['stop'],
    'a.list'                     => [ 'x', 2, $true ],
    'a.hash'                     => { a => 1, b => 2 },
    'typed.raw'                  => { intValue => '9' },
    'undef.attr'                 => undef,
    'gen_ai.usage.reasoning.output_tokens' => 'many',
  } ) ] ) ) };
  my $a = attrs_of($s);

  is_deeply( $a->{'gen_ai.usage.input_tokens'},  { intValue => '12' }, 'token count intValue as decimal string' );
  is_deeply( $a->{'gen_ai.usage.output_tokens'}, { intValue => '7' },  'numeric string token count -> intValue' );
  is_deeply( $a->{'gen_ai.request.max_tokens'},  { intValue => '256' }, 'max_tokens int' );
  is_deeply( $a->{'gen_ai.request.seed'},        { intValue => '42' },  'seed int' );
  is_deeply( $a->{'server.port'},                { intValue => '8443' }, 'server.port int' );
  is_deeply( $a->{'gen_ai.request.temperature'}, { doubleValue => 0 }, 'temperature 0 is a double, not dropped' );
  is_deeply( $a->{'gen_ai.request.top_p'},       { doubleValue => 0.9 }, 'top_p numeric string -> double' );
  is_deeply( $a->{'gen_ai.response.time_to_first_chunk'}, { doubleValue => 0.25 }, 'ttft double' );
  ok( $a->{'gen_ai.request.stream'}{boolValue}, 'stream boolValue true' );
  is_deeply( $a->{'gen_ai.response.id'},    { stringValue => '1234567890' }, 'numeric-looking response id stays a string' );
  is_deeply( $a->{'gen_ai.response.model'}, { stringValue => '4' }, 'numeric-looking model stays a string' );
  is_deeply( $a->{'gen_ai.request.model'},  { stringValue => '1e3' }, 'exponent-looking model stays a string' );
  is_deeply( $a->{'plain.number'},          { stringValue => '5' }, 'unknown numeric attribute is a string' );
  ok( exists $a->{'a.bool'}{boolValue} && !$a->{'a.bool'}{boolValue}, 'JSON false -> boolValue false' );
  is_deeply( $a->{'gen_ai.response.finish_reasons'}, { arrayValue => { values => [ { stringValue => 'stop' } ] } },
    'finish_reasons arrayValue.values' );
  is_deeply( $a->{'a.list'}{arrayValue}{values}[0], { stringValue => 'x' }, 'array element 1' );
  is_deeply( $a->{'a.list'}{arrayValue}{values}[1], { stringValue => '2' }, 'array element 2 string' );
  ok( $a->{'a.list'}{arrayValue}{values}[2]{boolValue}, 'array element 3 bool' );
  is_deeply( $a->{'a.hash'}, { stringValue => '{"a":1,"b":2}' }, 'HashRef sent as JSON text' );
  is_deeply( $a->{'typed.raw'}, { intValue => '9' }, 'single-key AnyValue hash passed through' );
  ok( !exists $a->{'undef.attr'}, 'undef attribute left out' );
  is_deeply( $a->{'gen_ai.usage.reasoning.output_tokens'}, { stringValue => 'many' },
    'value that does not fit its type goes as string, not dropped' );

  my $wire = $OTLP->new->to_json( [ rec( attributes => { 'gen_ai.usage.input_tokens' => 12,
    'gen_ai.request.temperature' => 0.5, 'gen_ai.request.stream' => 1 } ) ] );
  like( $wire, qr/"intValue":"12"/, 'intValue serialized as JSON string' );
  like( $wire, qr/"doubleValue":0\.5/, 'doubleValue serialized as JSON number' );
  like( $wire, qr/"boolValue":true/, 'stream => 1 serialized as JSON true' );

  my @keys = map { $_->{key} } @{ $s->{attributes} };
  is_deeply( \@keys, [ sort @keys ], 'attributes sorted by key' );
};

subtest 'ids' => sub {
  my %seen;
  for my $n ( 1 .. 50 ) {
    my $trace_id = $OTLP->new_trace_id;
    my $span_id  = $OTLP->new_span_id;
    if ( $n == 1 ) {
      like( $trace_id, qr/\A[0-9a-f]{32}\z/, 'trace id shape' );
      like( $span_id,  qr/\A[0-9a-f]{16}\z/, 'span id shape' );
    }
    ok( 0, 'zero id' ) if $trace_id =~ /\A0+\z/ || $span_id =~ /\A0+\z/;
    $seen{$trace_id}++;
  }
  is_deeply( scalar keys %seen, 50, 'trace ids are unique' );
};

subtest 'usage_attributes: the input-token rule' => sub {
  my %u = $OTLP->usage_attributes( Langertha::Usage->new( input_tokens => 100, output_tokens => 20 ) );
  is_deeply( \%u, { 'gen_ai.usage.input_tokens' => 100, 'gen_ai.usage.output_tokens' => 20 },
    'plain usage: only input/output' );

  %u = $OTLP->usage_attributes( Langertha::Usage->new( input_tokens => 100, output_tokens => 20,
    cached_tokens => 30, cache_write_tokens => 5 ) );
  is_deeply( $u{'gen_ai.usage.input_tokens'}, 100, 'undef includes_cache: input as given' );
  is_deeply( $u{'gen_ai.usage.cache_read.input_tokens'}, 30, 'cache read' );
  is_deeply( $u{'gen_ai.usage.cache_creation.input_tokens'}, 5, 'cache creation' );

  %u = $OTLP->usage_attributes( Langertha::Usage->new( input_tokens => 100, output_tokens => 20,
    cached_tokens => 30, cache_write_tokens => 5, input_includes_cache => 1 ) );
  is_deeply( $u{'gen_ai.usage.input_tokens'}, 100, 'includes_cache true: input as given' );

  %u = $OTLP->usage_attributes( Langertha::Usage->new( input_tokens => 100, output_tokens => 20,
    cached_tokens => 30, cache_write_tokens => 5, input_includes_cache => 0 ) );
  is_deeply( $u{'gen_ai.usage.input_tokens'}, 135, 'includes_cache false: input + cache read + cache write' );
  is_deeply( $u{'gen_ai.usage.cache_read.input_tokens'}, 30, 'cache read still reported' );
  is_deeply( $u{'gen_ai.usage.cache_creation.input_tokens'}, 5, 'cache creation still reported' );

  %u = $OTLP->usage_attributes( Langertha::Usage->new( input_tokens => 100, output_tokens => 20,
    cached_tokens => 30, input_includes_cache => 0 ) );
  is_deeply( $u{'gen_ai.usage.input_tokens'}, 130, 'includes_cache false, no cache write' );

  %u = $OTLP->usage_attributes( Langertha::Usage->new( input_tokens => 100, output_tokens => 20,
    input_includes_cache => 0 ) );
  is_deeply( $u{'gen_ai.usage.input_tokens'}, 100, 'includes_cache false, no cache numbers' );

  %u = $OTLP->usage_attributes( Langertha::Usage->new( input_tokens => 1, output_tokens => 1,
    cached_tokens => 0, cache_write_tokens => 0, reasoning_tokens => 0 ) );
  is_deeply( [ sort keys %u ], [ 'gen_ai.usage.input_tokens', 'gen_ai.usage.output_tokens' ],
    'zero cache / reasoning counts are left out' );

  %u = $OTLP->usage_attributes( Langertha::Usage->new( input_tokens => 1, output_tokens => 9, reasoning_tokens => 4 ) );
  is_deeply( $u{'gen_ai.usage.reasoning.output_tokens'}, 4, 'reasoning tokens when non-zero' );

  is_deeply( [ $OTLP->usage_attributes(undef) ], [], 'undef usage: nothing' );
  is_deeply( [ $OTLP->usage_attributes( {} ) ], [], 'non-Usage: nothing' );
};

subtest 'response_attributes' => sub {
  my $usage = Langertha::Usage->new( input_tokens => 10, output_tokens => 3 );
  my $r = Langertha::Response->new( content => 'hi', id => '12345', model => '678', finish_reason => 'end_turn',
    usage => $usage, timing => { ttft_seconds => 0.125, total_seconds => 1 } );
  my %a = $OTLP->response_attributes($r);
  is_deeply( $a{'gen_ai.response.id'}, '12345', 'id' );
  is_deeply( $a{'gen_ai.response.model'}, '678', 'model' );
  is_deeply( $a{'gen_ai.response.finish_reasons'}, ['end_turn'], 'finish_reasons is a one-element array of the raw value' );
  is_deeply( $a{'gen_ai.response.time_to_first_chunk'}, 0.125, 'ttft' );
  is_deeply( $a{'gen_ai.usage.input_tokens'}, 10, 'usage merged' );
  is_deeply( $a{'gen_ai.usage.output_tokens'}, 3, 'usage merged' );
  ok( !exists $a{'gen_ai.system'}, 'deprecated gen_ai.system never emitted' );

  my %bare = $OTLP->response_attributes( Langertha::Response->new( content => 'x' ) );
  is_deeply( \%bare, {}, 'a bare response contributes nothing' );
  is_deeply( [ $OTLP->response_attributes('str') ], [], 'non-Response: nothing' );

  my ($s) = @{ spans_of( payload_of( [ rec( attributes => \%a ) ] ) ) };
  my $wire = attrs_of($s);
  is_deeply( $wire->{'gen_ai.response.id'}, { stringValue => '12345' }, 'id stringValue on the wire' );
  is_deeply( $wire->{'gen_ai.response.model'}, { stringValue => '678' }, 'model stringValue on the wire' );
  is_deeply( $wire->{'gen_ai.usage.input_tokens'}, { intValue => '10' }, 'tokens intValue on the wire' );
};

subtest 'call_result_attributes' => sub {
  my $usage = Langertha::Usage->new( input_tokens => 5, output_tokens => 0 );
  my $result = Langertha::CallResult->new( value => [1], usage => $usage, model => 'emb-v2' );
  my %a = $OTLP->call_result_attributes($result);
  is_deeply( $a{'gen_ai.response.model'}, 'emb-v2', 'model' );
  is_deeply( $a{'gen_ai.usage.input_tokens'}, 5, 'usage' );
  is_deeply( [ $OTLP->call_result_attributes( Langertha::CallResult->new( value => 1 ) ) ], [], 'empty CallResult' );
  is_deeply( [ $OTLP->call_result_attributes('x') ], [], 'non-CallResult' );
};

subtest 'provider_name table' => sub {
  my %want = (
    OpenAI => 'openai', OpenAIResponses => 'openai', Anthropic => 'anthropic', Gemini => 'gcp.gemini',
    Mistral => 'mistral_ai', Groq => 'groq', DeepSeek => 'deepseek', XAI => 'x_ai',
    Perplexity => 'perplexity', Ollama => 'ollama', OllamaOpenAI => 'ollama',
    Moonshot => 'moonshot_ai', MoonshotAnthropic => 'moonshot_ai', MiniMax => 'minimax',
    MiniMaxAnthropic => 'minimax', AKI => 'aki', AKIOpenAI => 'aki', AKIAnthropic => 'aki',
    OpenRouter => 'openrouter', HuggingFace => 'huggingface', Replicate => 'replicate',
    vLLM => 'vllm', VLLMHook => 'vllm', SGLang => 'sglang', LlamaCpp => 'llama_cpp',
    LMStudio => 'lm_studio', LMStudioOpenAI => 'lm_studio', LMStudioAnthropic => 'lm_studio',
    NousResearch => 'nous_research', TSystems => 't_systems', Scaleway => 'scaleway',
    Hetzner => 'hetzner', Cerebras => 'cerebras', Whisper => 'whisper',
    Virtual => 'langertha.virtual', Mock => 'langertha.virtual',
  );
  for my $engine ( sort keys %want ) {
    require_ok_class("Langertha::Engine::$engine");
    is_deeply( $OTLP->provider_name("Langertha::Engine::$engine"), $want{$engine}, "$engine -> $want{$engine}" );
  }

  # Every shipped engine class must resolve to a real provider name: a new
  # engine has to be added to the table, or it is exported as _OTHER.
  my $dir = $INC{'Langertha/Trace/OTLP.pm'};
  $dir =~ s{Trace/OTLP\.pm\z}{Engine};
  opendir my $dh, $dir or die "cannot read $dir: $!";
  my @shipped = sort map { s/\.pm\z//r } grep { /\.pm\z/ } readdir $dh;
  closedir $dh;
  my %is_base = map { $_ => 1 } qw( Remote OpenAIBase AnthropicBase TranscriptionBase );
  for my $engine ( grep { !$is_base{$_} } @shipped ) {
    ok( exists $want{$engine}, "engine $engine is covered by the provider table test" );
  }

  my $openai = Langertha::Engine::OpenAI->new( api_key => 'k' );
  is_deeply( $OTLP->provider_name($openai), 'openai', 'object works as well as class' );
  {
    package My::Sub::OpenAI;
    use Moose;
    extends 'Langertha::Engine::OpenAI';
    __PACKAGE__->meta->make_immutable;
    package My::Sub::Deep;
    use Moose;
    extends 'My::Sub::OpenAI';
    __PACKAGE__->meta->make_immutable;
    package My::Unrelated;
    use Moose;
    __PACKAGE__->meta->make_immutable;
  }
  is_deeply( $OTLP->provider_name('My::Sub::OpenAI'), 'openai', 'subclass resolves via isa' );
  is_deeply( $OTLP->provider_name('My::Sub::Deep'), 'openai', 'deep subclass resolves via isa' );
  is_deeply( $OTLP->provider_name( My::Sub::Deep->new( api_key => 'k' ) ), 'openai', 'subclass object' );
  is_deeply( $OTLP->provider_name('My::Unrelated'), '_OTHER', 'unknown class -> _OTHER' );
  is_deeply( $OTLP->provider_name('Langertha::Engine::OpenAIBase'), '_OTHER', 'base class is not a provider' );
  is_deeply( $OTLP->provider_name(undef), '_OTHER', 'undef -> _OTHER' );
  is_deeply( $OTLP->provider_name(''), '_OTHER', 'empty -> _OTHER' );
};

sub require_ok_class {
  my ($class) = @_;
  (my $file = "$class.pm") =~ s{::}{/}g;
  ok( eval { require $file; 1 }, "$class loads" ) or diag $@;
}

subtest 'request_attributes' => sub {
  my $engine = Langertha::Engine::OpenAI->new( api_key => 'k', url => 'https://llm.example.com:8443/v1',
    chat_model => 'gpt-test', temperature => 0.3, response_size => 99 );
  my %a = $OTLP->request_attributes($engine);
  is_deeply( $a{'gen_ai.operation.name'}, 'chat', 'default operation chat' );
  is_deeply( $a{'gen_ai.provider.name'}, 'openai', 'provider' );
  is_deeply( $a{'gen_ai.request.model'}, 'gpt-test', 'model' );
  is_deeply( $a{'server.address'}, 'llm.example.com', 'server.address' );
  is_deeply( $a{'server.port'}, 8443, 'server.port' );
  is_deeply( $a{'gen_ai.request.temperature'}, 0.3, 'temperature' );
  is_deeply( $a{'gen_ai.request.max_tokens'}, 99, 'max_tokens' );
  ok( !exists $a{'gen_ai.output.type'}, 'no output type without response_format' );
  ok( !exists $a{'gen_ai.system'}, 'no deprecated gen_ai.system' );

  my %o = $OTLP->request_attributes( $engine, model => 'override', temperature => 0.9, provider_name => 'custom' );
  is_deeply( $o{'gen_ai.request.model'}, 'override', 'model override' );
  is_deeply( $o{'gen_ai.request.temperature'}, 0.9, 'temperature override' );
  is_deeply( $o{'gen_ai.provider.name'}, 'custom', 'provider override' );

  my $plain = Langertha::Engine::OpenAI->new( api_key => 'k', chat_model => 'm' );
  my %p = $OTLP->request_attributes($plain);
  ok( !exists $p{'gen_ai.request.temperature'}, 'unset temperature left out' );
  ok( !exists $p{'gen_ai.request.max_tokens'}, 'unset max_tokens left out' );
  ok( !exists $p{'gen_ai.request.seed'}, 'unset seed left out' );

  require Langertha::Engine::Ollama;
  my $ollama = Langertha::Engine::Ollama->new( url => 'http://localhost:11434', model => 'llama', seed => 7 );
  my %seeded = $OTLP->request_attributes($ollama);
  is_deeply( $seeded{'gen_ai.request.seed'}, 7, 'seed (an engine with the Seed role)' );
  is_deeply( $seeded{'gen_ai.provider.name'}, 'ollama', 'ollama provider' );

  my %e = $OTLP->request_attributes( $engine, operation => 'embeddings' );
  is_deeply( $e{'gen_ai.operation.name'}, 'embeddings', 'embeddings operation' );
  ok( !exists $e{'gen_ai.request.temperature'}, 'no chat parameters on embeddings' );
  like( $e{'gen_ai.request.model'}, qr/\S/, 'embedding model from embedding_model' );
};

subtest 'typed attribute coercion: integers, booleans, caller AnyValue' => sub {
  my $value_of = sub {
    my ( $key, $value ) = @_;
    my $p = payload_of( [ rec( attributes => { $key => $value } ) ] );
    return attrs_of( spans_of($p)->[0] )->{$key};
  };
  my $int = 'gen_ai.usage.input_tokens';
  my $max = 'gen_ai.request.max_tokens';
  my @int_cases = (
    [ $int, 12,                     { intValue => '12' } ],
    [ $int, 12.0,                   { intValue => '12' } ],
    [ $max, '1.2e1',                { intValue => '12' } ],
    [ $max, '12.0',                 { intValue => '12' } ],
    [ $int, 1e20,                   { stringValue => '1e+20' } ],
    [ $int, '9223372036854775808',  { stringValue => '9223372036854775808' } ],
    [ $int, '-9223372036854775809', { stringValue => '-9223372036854775809' } ],
    [ $max, 1.5,                    { stringValue => '1.5' } ],
    [ $int, '9223372036854775807',  { intValue => '9223372036854775807' } ],
    [ $int, '-9223372036854775808', { intValue => '-9223372036854775808' } ],
  );
  for my $case (@int_cases) {
    my ( $key, $in, $want ) = @$case;
    is_deeply( $value_of->( $key, $in ), $want, "$key => '$in'" );
  }

  my $stream = 'gen_ai.request.stream';
  my @bool_cases = (
    [ 'true',  { boolValue => JSON::MaybeXS::true() } ],
    [ 'FALSE', { boolValue => JSON::MaybeXS::false() } ],
    [ '',      { boolValue => JSON::MaybeXS::false() } ],
    [ '0.0',   { boolValue => JSON::MaybeXS::false() } ],
    [ 'yes',   { stringValue => 'yes' } ],
    [ 2,       { stringValue => '2' } ],
  );
  for my $case (@bool_cases) {
    my ( $in, $want ) = @$case;
    is_deeply( $value_of->( $stream, $in ), $want, "$stream => '$in'" );
  }

  is_deeply( $value_of->( 'custom.key', { intValue => '9.0' } ), { intValue => '9' }, 'caller intValue "9.0" normalized to "9"' );
  is_deeply( $value_of->( 'custom.key', { intValue => 'x' } ), { stringValue => 'x' }, 'caller intValue "x" is sent as a string' );
};

done_testing;
