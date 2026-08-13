package Langertha::Runtime::Metrics;
# ABSTRACT: Prometheus text exposition format parser with prefix filter
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );
use Scalar::Util qw( blessed );

=head1 SYNOPSIS

    use Langertha::Runtime::Metrics;

    my $metrics = Langertha::Runtime::Metrics->new;

    my $records = $metrics->parse($prometheus_payload);

    # Filter to engine-specific keys only
    my $vllm_only = $metrics->filter_prefix($records, 'vllm:');

    # Same, in one step
    my $vllm_only = $metrics->parse_and_filter($prometheus_payload, 'vllm:');

=head1 DESCRIPTION

Parser for the Prometheus text exposition format. Accepts a raw
payload string (the body of a C<GET /metrics> response) and returns
an ArrayRef of HashRefs with shape:

    {
      name   => 'vllm:gpu_cache_usage_perc',   # metric name (str)
      type   => 'gauge',                       # counter | gauge | histogram |
                                                # summary | untyped
      value  => 0.42,                          # numeric value
      labels => { model_name => 'Qwen/Qwen2.5-7B-Instruct' },  # label set
                                                # (HashRef, possibly empty)
    }

Only sample lines are returned. C<# HELP> and C<# TYPE> directive lines
inform the C<type> field on the following sample(s) but are not emitted
on their own.

Counter / gauge / untyped lines yield a single record each. Histogram
and summary lines yield one record per emitted series (the C<_bucket>,
C<_sum>, and C<_count> series that follow the C<# TYPE histogram>
directive).

The parser is intentionally permissive: malformed lines are skipped
with a warning rather than croaking, so a partial scrape (truncated
body, comment-only line at EOF) returns the lines it could parse
rather than nothing.

=head2 Wire contract

The exact metric-key shape per engine lives in
L<Langertha::Runtime::Metrics::EngineContract>. Use C<filter_prefix> to
restrict the parser output to that engine's allowlist before doing
anything with the records (logging, OTLP export, etc.) — Prometheus
C<process_*> and C<go_*> entries ship from the same /metrics body and
are not engine-specific.

=cut

has _default_type => (
  is      => 'ro',
  isa     => 'Str',
  default => 'untyped',
);

sub parse {
  my ( $self, $payload ) = @_;
  croak "parse() requires a payload string"
    unless defined $payload && ref($payload) ne 'HASH';

  my @records;
  my %type_for;

  for my $line ( split /\r?\n/, $payload ) {
    next if $line eq '';
    next if $line =~ /^\s*$/;

    if ( $line =~ /^\#\s*TYPE\s+(\S+)\s+(\S+)\s*$/ ) {
      $type_for{$1} = $2;
      next;
    }
    next if $line =~ /^\s*#/;       # HELP and other directives

    # Sample line.

    # Sample line. Three shapes per the Prometheus spec:
    #   metric_name [labels] value [timestamp]
    #   metric_name value [timestamp]
    # Prometheus values are always numeric (or the special floats NaN /
    # +Inf / -Inf), so we anchor the value group to that — without the
    # numeric anchor, plain English lines like "this is a comment" match
    # the lenient name+value pattern and become bogus records.
    my ( $name, $labels_str, $value );
    if ( $line =~ /^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+(-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?|NaN|\+?Inf|-Inf)/ ) {
      ( $name, $labels_str, $value ) = ( $1, $2, $3 );
    }
    else {
      # Unparseable — skip rather than croak; partial scrapes survive.
      next;
    }

    my $labels = $self->_parse_labels($labels_str);
    my $numeric = 0 + $value;   # numeric coercion; non-numeric values (NaN,
                                # +Inf) round-trip as 0 / inf in Perl — good
                                # enough for the shape contract.

    push @records, {
      name   => $name,
      type   => $self->_resolve_type(\%type_for, $name) || $self->_default_type,
      value  => $numeric,
      labels => $labels,
    };
  }

  return \@records;
}

# Resolve the declared TYPE for a series name. Histograms and summaries
# emit TYPE for the base name only — `_bucket`, `_sum`, `_count` (and the
# summary's analogous suffixes) inherit it. Look up the most-specific
# match first, then walk the name progressively left-to-right.
sub _resolve_type {
  my ( $self, $type_for, $name ) = @_;
  return $type_for->{$name} if exists $type_for->{$name};
  my @parts = split /_/, $name;
  while ( @parts > 1 ) {
    pop @parts;
    my $candidate = join '_', @parts;
    return $type_for->{$candidate} if exists $type_for->{$candidate};
  }
  return undef;
}

=method parse

    my $records = $metrics->parse($payload);

Parses a Prometheus text-format payload into an ArrayRef of
C<< { name, type, value, labels } >> HashRefs. See L</DESCRIPTION> for
the exact shape. Malformed lines are skipped, never fatal.

=cut

sub _parse_labels {
  my ( $self, $labels_str ) = @_;
  return {} unless defined $labels_str && length $labels_str;
  # Strip surrounding braces
  $labels_str =~ s/^\{//;
  $labels_str =~ s/\}$//;
  return {} unless length $labels_str;

  my %labels;
  # Naive label parser: split on commas at the top level, then on the
  # first '=' per pair. Prometheus label values may contain commas,
  # backslashes, and double-quotes when escaped — we handle the common
  # unescaped case (which is what every shipped engine emits). Escape
  # handling can be tightened later if a real payload demands it.
  for my $pair ( split /,/, $labels_str ) {
    next unless $pair =~ /^([^=]+)="(.*)"\s*$/;
    my ( $k, $v ) = ( $1, $2 );
    $v =~ s/\\"/"/g;
    $v =~ s/\\\\/\\/g;
    $v =~ s/\\n/\n/g;
    $labels{$k} = $v;
  }
  return \%labels;
}

sub filter_prefix {
  my ( $self, $records, $prefix ) = @_;
  croak "filter_prefix() requires an ArrayRef of records"
    unless ref($records) eq 'ARRAY';
  croak "filter_prefix() requires a string prefix"
    unless defined $prefix && !ref($prefix);
  my @filtered = grep { defined $_->{name} && index( $_->{name}, $prefix ) == 0 } @$records;
  return \@filtered;
}

=method filter_prefix

    my $vllm = $metrics->filter_prefix($records, 'vllm:');
    my $sg    = $metrics->filter_prefix($records, 'sglang:');
    my $llama = $metrics->filter_prefix($records, 'llama_');

Returns the subset of C<$records> whose C<name> starts with the given
prefix. Use to restrict parser output to the engine's allowlist per
L<Langertha::Runtime::Metrics::EngineContract>.

=cut

sub parse_and_filter {
  my ( $self, $payload, @prefixes ) = @_;
  my $records = $self->parse($payload);
  return $records unless @prefixes;
  my @kept;
  PREFIX: for my $r ( @$records ) {
    for my $p ( @prefixes ) {
      if ( defined $r->{name} && index( $r->{name}, $p ) == 0 ) {
        push @kept, $r;
        next PREFIX;
      }
    }
  }
  return \@kept;
}

=method parse_and_filter

    my $vllm = $metrics->parse_and_filter($payload, 'vllm:');
    my $both = $metrics->parse_and_filter($payload, 'vllm:', 'http:');

Convenience wrapper around L</parse> + L</filter_prefix>. Multiple
prefixes are OR-ed (a record is kept if it matches B<any> prefix).

=cut

__PACKAGE__->meta->make_immutable;

=seealso

=over 4

=item * L<Langertha::Runtime::Metrics::EngineContract> - Per-engine wire contract (allowlist prefixes, URL paths)

=item * L<Langertha::Role::Runtime::MetricsPoll> - Async scraper that drives this parser

=item * L<Langertha::Runtime::Metrics::OTLP> - Serializes the record shape into an OTLP/HTTP JSON metrics payload

=item * L<https://prometheus.io/docs/instrumenting/exposition_formats/> - Prometheus text exposition format spec

=back

=cut

1;
