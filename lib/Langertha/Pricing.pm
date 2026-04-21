package Langertha::Pricing;
# ABSTRACT: Model→price catalog producing Langertha::Cost from Langertha::Usage
our $VERSION = '0.404';
use Moose;
use Langertha::Cost;

# Map of model id → { input_per_million => N, output_per_million => N }.
# Both keys are USD per 1,000,000 tokens.
has rules => (
  is      => 'ro',
  isa     => 'HashRef',
  default => sub { {} },
);

# Optional fallback rule applied when a model id is unknown.
has default_rule => (
  is      => 'ro',
  isa     => 'Maybe[HashRef]',
  default => sub { undef },
);

sub rule_for {
  my ($self, $model) = @_;
  return $self->rules->{$model} if defined $model && exists $self->rules->{$model};
  return $self->default_rule;
}

sub cost_for {
  my ($self, $usage, $model) = @_;
  my $rule = $self->rule_for($model) || {};
  my $ipm = 0 + ( $rule->{input_per_million}  // 0 );
  my $opm = 0 + ( $rule->{output_per_million} // 0 );
  my $input_usd  = ( $usage->input_tokens  / 1_000_000 ) * $ipm;
  my $output_usd = ( $usage->output_tokens / 1_000_000 ) * $opm;
  return Langertha::Cost->new(
    input_usd  => $input_usd,
    output_usd => $output_usd,
  );
}

__PACKAGE__->meta->make_immutable;
1;
