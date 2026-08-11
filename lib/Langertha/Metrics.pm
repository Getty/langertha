package Langertha::Metrics;
our $VERSION = '0.503';
our $DEPRECATED = 1;
# ABSTRACT: DEPRECATED back-compat facade over Langertha::Usage / Pricing / Cost / UsageRecord — use the value objects directly
use strict;
use warnings;
use Carp ();
use Langertha::Usage;
use Langertha::Pricing;
use Langertha::Cost;
use Langertha::UsageRecord;

Carp::carp(
  "Langertha::Metrics is a backwards-compatibility facade. New code should use "
  . "Langertha::Usage / Langertha::Pricing / Langertha::Cost / Langertha::UsageRecord directly."
);

# All methods here are kept for backwards compatibility with existing
# Skeid/Knarr code. New code should construct Langertha::Usage,
# Langertha::Pricing, and Langertha::UsageRecord directly.

=head1 DEPRECATION

Langertha::Metrics is a thin back-compat facade kept solely so existing
Skeid/Knarr consumers keep working. It is B<scheduled for removal in
Langertha 0.504>. New code must construct the value objects directly
— no replacement module, just stop calling this one.

Migration map (one-to-one):

=over 4

=item * C<normalize_usage($hash)>

= Langertha::Usage->from_hash($hash)->to_hash

=item * C<usage_from_response($response)>

= Langertha::Usage->from_response($response)->to_hash

=item * C<estimate_cost_usd(usage => ..., pricing => ...)>

= Langertha::Pricing->new( default_rule => $pricing )->cost_for(
  Langertha::Usage->from_hash($usage), $model
)->to_hash

=item * C<build_record(...)>

Construct L<Langertha::UsageRecord> directly: build a
L<Langertha::Usage> from the response or hash, build a
L<Langertha::Pricing> with the C<pricing> rule, call
C<< ->cost_for($usage, $model) >>, then C<< Langertha::UsageRecord->new(
usage => $usage, cost => $cost, provider => ..., engine => ..., model => ...,
route => ..., api_key_id => ..., duration_ms => ..., started_at => ...,
finished_at => ..., tool_calls => ..., tool_names => ...,
pricing_version => ... ) >> and C<< ->to_hash >>.

=back

Note: C<Langertha::Response>'s C<usage> attribute is the raw provider
payload as returned on the wire — it is B<unrelated> to this facade's
normalization helpers and is not affected by the deprecation.

=cut

sub normalize_usage {
  my ($class, $usage) = @_;
  return Langertha::Usage->from_hash($usage)->to_hash;
}

sub usage_from_response {
  my ($class, $response) = @_;
  return Langertha::Usage->from_response($response)->to_hash;
}

sub normalize_tool_metrics {
  my ($class, $tool_calls) = @_;
  my @names;
  for my $tc ( @{ $tool_calls || [] } ) {
    next unless ref($tc) eq 'HASH';
    my $name = $tc->{name};
    if ( !defined $name && ref( $tc->{function} ) eq 'HASH' ) {
      $name = $tc->{function}{name};
    }
    next unless defined $name && length $name;
    push @names, $name;
  }
  return {
    tool_calls => scalar(@names),
    tool_names => \@names,
  };
}

sub estimate_cost_usd {
  my ($class, %args) = @_;
  my $usage = Langertha::Usage->from_hash( $args{usage} || {} );
  my $rule  = $args{pricing} || {};
  my $pricing = Langertha::Pricing->new( default_rule => $rule );
  my $cost = $pricing->cost_for( $usage, undef );
  return $cost->to_hash;
}

sub build_record {
  my ($class, %args) = @_;
  my $usage = Langertha::Usage->from_hash(
    $args{usage}
      || ( ( $args{response} && ref( $args{response} ) eq 'HASH' ) ? $args{response}{usage} : {} )
      || {}
  );
  my $tool = $class->normalize_tool_metrics( $args{tool_calls} || [] );

  my $pricing_rule = $args{pricing} || {};
  my $pricing = Langertha::Pricing->new( default_rule => $pricing_rule );
  my $cost = $pricing->cost_for( $usage, $args{model} );

  my $record = Langertha::UsageRecord->new(
    usage           => $usage,
    cost            => $cost,
    provider        => $args{provider},
    engine          => $args{engine},
    model           => $args{model},
    route           => $args{route},
    api_key_id      => $args{api_key_id},
    duration_ms     => $args{duration_ms},
    started_at      => $args{started_at},
    finished_at     => $args{finished_at},
    tool_calls      => $tool->{tool_calls},
    tool_names      => $tool->{tool_names},
    pricing_version => $args{pricing_version},
  );
  return $record->to_hash;
}

1;
