package Langertha::UsageRecord;
# ABSTRACT: Tagged ledger entry combining Usage, Cost, and request metadata
our $VERSION = '0.404';
use Moose;
use Langertha::Usage;
use Langertha::Cost;

has usage => ( is => 'ro', isa => 'Langertha::Usage', required => 1 );
has cost  => ( is => 'ro', isa => 'Langertha::Cost', required => 1 );

has model    => ( is => 'ro', isa => 'Maybe[Str]' );
has provider => ( is => 'ro', isa => 'Maybe[Str]' );
has engine   => ( is => 'ro', isa => 'Maybe[Str]' );
has route    => ( is => 'ro', isa => 'Maybe[Str]' );
has endpoint => ( is => 'ro', isa => 'Maybe[Str]' );

has api_key_id => ( is => 'ro', isa => 'Maybe[Str]' );

has tool_calls => ( is => 'ro', isa => 'Int', default => 0 );
has tool_names => ( is => 'ro', isa => 'ArrayRef[Str]', default => sub { [] } );

has duration_ms => ( is => 'ro', isa => 'Maybe[Num]' );
has started_at  => ( is => 'ro', isa => 'Maybe[Num]' );
has finished_at => ( is => 'ro', isa => 'Maybe[Num]' );

has pricing_version => ( is => 'ro', isa => 'Maybe[Str]' );

sub to_hash {
  my ($self) = @_;
  return {
    provider        => $self->provider,
    engine          => $self->engine,
    model           => $self->model,
    route           => $self->route,
    endpoint        => $self->endpoint,
    api_key_id      => $self->api_key_id,
    duration_ms     => $self->duration_ms,
    started_at      => $self->started_at,
    finished_at     => $self->finished_at,
    input_tokens    => $self->usage->input_tokens,
    output_tokens   => $self->usage->output_tokens,
    total_tokens    => $self->usage->total_tokens,
    tool_calls      => $self->tool_calls,
    tool_names      => $self->tool_names,
    input_cost_usd  => $self->cost->input_usd  + 0,
    output_cost_usd => $self->cost->output_usd + 0,
    total_cost_usd  => $self->cost->total_usd  + 0,
    currency        => $self->cost->currency,
    pricing_version => $self->pricing_version,
  };
}

__PACKAGE__->meta->make_immutable;
1;
