package Langertha::RunContext;
# ABSTRACT: Shared execution context for Raid and Raider runs
our $VERSION = '0.308';
use Moose;
use Carp qw( croak );
use Scalar::Util qw( blessed );
use Storable qw( dclone );

=head1 SYNOPSIS

    my $ctx = Langertha::RunContext->new(
      input => 'start',
      state => { counter => 0 },
    );

    my $branch = $ctx->branch(metadata => { path => 'left' });
    $ctx->merge_branch($branch, slot => 'parallel', name => 'left');

=head1 DESCRIPTION

Carries structured execution state through runnable nodes. It is designed to
be safely propagated across sequential steps and branched for parallel steps.

=cut

has input => (
  is => 'rw',
);

=attr input

Current input payload for the next runnable step.

=cut

has state => (
  is      => 'rw',
  isa     => 'HashRef',
  default => sub { {} },
);

=attr state

Mutable workflow state shared across sequential execution.

=cut

has artifacts => (
  is      => 'rw',
  isa     => 'HashRef',
  default => sub { {} },
);

=attr artifacts

Structured outputs and intermediate artifacts produced by runs.

=cut

has metadata => (
  is      => 'rw',
  isa     => 'HashRef',
  default => sub { {} },
);

=attr metadata

Execution metadata (labels, counters, step info, etc.).

=cut

has trace => (
  is      => 'rw',
  isa     => 'ArrayRef',
  default => sub { [] },
);

=attr trace

Chronological trace entries describing orchestration progress.

=cut

has history => (
  is        => 'rw',
  isa       => 'ArrayRef',
  predicate => 'has_history',
);

=attr history

Optional conversation/history payload mirrored from Raider runs.

=cut

sub add_trace {
  my ( $self, $entry ) = @_;
  croak "trace entry must be a hashref"
    unless ref($entry) eq 'HASH';
  push @{$self->trace}, $entry;
  return $self;
}

=method add_trace

    $ctx->add_trace({ event => 'step_result', step => 1 });

Appends a trace hashref.

=cut

sub branch {
  my ( $self, %opts ) = @_;
  my $metadata = _clone_data($self->metadata);
  if ($opts{metadata}) {
    croak "branch metadata must be a hashref"
      unless ref($opts{metadata}) eq 'HASH';
    $metadata = { %{$metadata}, %{$opts{metadata}} };
  }

  my $branch = __PACKAGE__->new(
    input     => _clone_data(exists $opts{input} ? $opts{input} : $self->input),
    state     => _clone_data($self->state),
    artifacts => _clone_data($self->artifacts),
    metadata  => $metadata,
    trace     => _clone_data($self->trace),
    ($self->has_history ? (history => _clone_data($self->history)) : ()),
  );

  return $branch;
}

=method branch

    my $branch_ctx = $ctx->branch(metadata => { branch => 0 });

Creates an isolated context clone for parallel execution.

=cut

sub merge_branch {
  my ( $self, $branch, %opts ) = @_;
  croak "merge_branch expects a Langertha::RunContext"
    unless blessed($branch) && $branch->isa(__PACKAGE__);

  my $slot = $opts{slot} // 'branches';
  my $name = defined $opts{name}
    ? $opts{name}
    : scalar(keys %{$self->artifacts->{$slot} // {}});

  $self->artifacts->{$slot} = {}
    unless exists $self->artifacts->{$slot};
  croak "artifact slot '$slot' must be a hashref"
    unless ref($self->artifacts->{$slot}) eq 'HASH';

  $self->artifacts->{$slot}{$name} = {
    input     => _clone_data($branch->input),
    state     => _clone_data($branch->state),
    artifacts => _clone_data($branch->artifacts),
    metadata  => _clone_data($branch->metadata),
    trace     => _clone_data($branch->trace),
  };

  return $self;
}

=method merge_branch

    $ctx->merge_branch($branch_ctx, slot => 'parallel', name => 'step_a');

Stores an immutable snapshot of a branch context in the parent context.

=cut

sub _clone_data {
  my ( $data ) = @_;
  return $data unless ref($data);

  my $copy = eval { dclone($data) };
  return $copy if !$@;

  if (ref($data) eq 'HASH') {
    return { %{$data} };
  }
  if (ref($data) eq 'ARRAY') {
    return [ @{$data} ];
  }
  return $data;
}

__PACKAGE__->meta->make_immutable;

1;
