package Langertha::Manifest::Validation;
# ABSTRACT: Shared validation rules for the provider manifest value objects
our $VERSION = '0.503';
use Moose::Role;
use Carp qw( croak );
use Scalar::Util qw( blessed );
use URI;
use JSON::MaybeXS ();

# Report validation errors at the caller of the manifest API, not inside it.
our @CARP_NOT = qw(
  Langertha::Manifest Langertha::Manifest::Endpoint Langertha::Manifest::Auth
  Langertha::Manifest::Model Langertha::Manifest::Builder
);

=head1 SYNOPSIS

    package Langertha::Manifest::Endpoint;
    use Moose;
    with 'Langertha::Manifest::Validation';

    sub from_hash {
      my ( $class, $data ) = @_;
      $class->check_manifest_fields( $data,
        required => [qw( id dialect base_url )],
        optional => [qw( auth_ref )],
      );
      return $class->new(%$data);
    }

=head1 DESCRIPTION

The rules every part of a L<Langertha::Manifest> shares: the explicit
rejection of command-, code-, secret- and prompt-shaped fields, the
rejection of unknown fields, and the value checks for ids, tokens and URLs.
Composed by L<Langertha::Manifest>, L<Langertha::Manifest::Endpoint>,
L<Langertha::Manifest::Auth> and L<Langertha::Manifest::Model>.

This is an internal role of the manifest value objects, not an engine
capability; it lives outside C<Langertha::Role::> on purpose.

=cut

# A field whose name contains one of these words is rejected explicitly,
# before the unknown-field check, so the error says WHY: a manifest comes from
# the network and never carries anything that could run a command, load code,
# point at a local secret or inject a prompt (langertha-raider ADR 0007). No v1
# field name contains any of these words.
my %FORBIDDEN_WORD = map { $_ => 1 } qw(
  command commands cmd exec shell script run install hook hooks
  class module package code eval require plugin plugins perl
  secret secrets password token credential credentials key apikey env path file
  prompt mission mcp packs skills tools
);

sub _field_words {
  my ($name) = @_;
  ( my $split = $name ) =~ s/([a-z0-9])([A-Z])/$1_$2/g;
  return grep { length } split /[_\-.\s]+/, lc $split;
}

sub is_forbidden_manifest_field {
  my ( $class, $name ) = @_;
  return scalar grep { $FORBIDDEN_WORD{$_} } _field_words($name);
}

=method is_forbidden_manifest_field

    Langertha::Manifest->is_forbidden_manifest_field('api_key');  # true

True when a field name contains a word from the forbidden list (commands,
code, secrets, secret paths, prompts, tool/pack/skill injection). Names are
split on C<_>, C<->, C<.> and camelCase boundaries, case-insensitively.

=cut

sub manifest_error {
  my ( $class, $message ) = @_;
  croak "Langertha::Manifest: $message";
}

sub check_manifest_fields {
  my ( $class, $data, %spec ) = @_;
  $class->manifest_error('must be a JSON object') unless ref $data eq 'HASH';
  my %allowed = map { $_ => 1 } @{ $spec{required} || [] }, @{ $spec{optional} || [] };
  for my $field ( sort keys %$data ) {
    next if $allowed{$field};
    $class->manifest_error( "forbidden field '$field': a manifest never carries "
      . 'commands, code, secrets or prompts' )
      if $class->is_forbidden_manifest_field($field);
    $class->manifest_error("unknown field '$field'");
  }
  for my $field ( @{ $spec{required} || [] } ) {
    $class->manifest_error("field '$field' is required")
      unless defined $data->{$field};
  }
  return;
}

=method check_manifest_fields

    $class->check_manifest_fields( $hashref,
      required => [ ... ], optional => [ ... ] );

Croaks unless C<$hashref> is a HashRef whose keys are all in the required or
optional lists and every required key is defined. A key outside both lists is
reported as I<forbidden> when its name is command/code/secret/prompt-shaped,
otherwise as I<unknown>.

=cut

my $ID_RE = qr/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/;

sub check_manifest_id {
  my ( $class, $what, $value ) = @_;
  $class->manifest_error( "$what must match [A-Za-z0-9][A-Za-z0-9._-]* (max 64), got '"
    . ( $value // '' ) . q{'} )
    unless defined $value && !ref $value && $value =~ $ID_RE;
  return;
}

=method check_manifest_id

Croaks unless the value is a local manifest id (endpoint / auth id or
reference): C<[A-Za-z0-9][A-Za-z0-9._-]*>, at most 64 characters.

=cut

sub check_manifest_token {
  my ( $class, $what, $value ) = @_;
  $class->manifest_error( "$what must match [a-z][a-z0-9_-]*, got '" . ( $value // '' ) . q{'} )
    unless defined $value && !ref $value && $value =~ /\A[a-z][a-z0-9_-]{0,63}\z/;
  return;
}

=method check_manifest_token

Croaks unless the value is a lower-case vocabulary token (dialect, auth
type): C<[a-z][a-z0-9_-]*>, at most 64 characters.

=cut

sub check_manifest_url {
  my ( $class, $what, $value ) = @_;
  $class->manifest_error("$what: must be an http or https URL")
    unless defined $value && !ref $value && length $value;
  my $uri = URI->new($value);
  my $scheme = $uri->scheme // '';
  $class->manifest_error("$what: must be an http or https URL, got '$value'")
    unless ( $scheme eq 'http' || $scheme eq 'https' ) && length( $uri->host // '' );
  $class->manifest_error("$what: must not carry userinfo (credentials) in the URL")
    if defined $uri->userinfo;
  $class->manifest_error("$what: must not carry a query string (secrets hide there)")
    if defined $uri->query;
  $class->manifest_error("$what: must not carry a fragment")
    if defined $uri->fragment;
  return;
}

=method check_manifest_url

Croaks unless the value is an C<http>/C<https> URL with a host and without
userinfo, query string or fragment — the places a credential could be
smuggled into a published URL.

=cut

sub manifest_bool {
  my ( $class, $what, $value ) = @_;
  if ( JSON::MaybeXS::is_bool($value) ) { return $value ? 1 : 0 }
  if ( ref $value eq 'SCALAR' && defined $$value && $$value =~ /\A[01]\z/ ) { return 0 + $$value }
  if ( defined $value && !ref $value && $value =~ /\A[01]\z/ ) { return 0 + $value }
  $class->manifest_error("$what must be a boolean");
  return;
}

=method manifest_bool

Normalizes a boolean — a JSON boolean, C<\1>/C<\0> or C<1>/C<0> — to C<1>
or C<0>; croaks on anything else (a string such as C<"yes"> is not a
boolean).

=cut

sub rethrow_manifest_error {
  my ( $class, $path, $error ) = @_;
  my $message = blessed($error) && $error->can('message') ? $error->message : "$error";
  $message =~ s/\s+at \S+ line \d+\.?\s*\z//s;
  $message =~ s/\s+\z//;
  $message =~ s/\ALangertha::Manifest(?:::\w+)?: //;
  croak "Langertha::Manifest: $path: $message";
}

=method rethrow_manifest_error

    $class->rethrow_manifest_error( 'endpoints[0]', $@ );

Re-raises a validation error with the location inside the document
prefixed, so every rejection reads C<Langertha::Manifest: E<lt>pathE<gt>: E<lt>reasonE<gt>>.

=cut

=seealso

=over

=item * L<Langertha::Manifest> - The provider manifest

=back

=cut

1;
