package Langertha::Virtual::Rules;
# ABSTRACT: Helpers that build the rules of Langertha::Engine::Virtual
our $VERSION = '0.504';
use strict;
use warnings;
use Carp qw( croak );
use Exporter 'import';

our @EXPORT_OK   = qw( answer tool tools after error );
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

=head1 SYNOPSIS

    use Langertha::Engine::Virtual;
    use Langertha::Virtual::Rules qw( answer tool tools after error );

    my $engine = Langertha::Engine::Virtual->new(
      rules => [
        'Hello'                 => answer('Hi there'),
        qr/\ARead (\S+)\z/      => sub { my ( $req, $path ) = @_; tool( read_file => { path => $path } ) },
        'Look around'           => tools( [ [ bash => { command => 'ls' } ], [ bash => { command => 'pwd' } ] ] ),
        after('read_file')      => answer('I read it.'),
      ],
      fallback => answer('I do not know that one.'),
    );

=head1 DESCRIPTION

Small functions that build the data L<Langertha::Engine::Virtual> reads as
reactions and triggers. They return plain Perl data, so a rule written
without them works the same: C<answer('x')> is C<< { answer => 'x' } >>.
Nothing is exported by default; ask for the names, or C<:all>.

C<after> shares its name with the L<Moose> method modifier: import it into a
test script or a plain package, not into a L<Moose> class, or call it as
C<Langertha::Virtual::Rules::after(...)>.

=head1 FUNCTIONS

=cut

sub answer {
  my ( $text ) = @_;
  croak __PACKAGE__.'::answer needs a text' unless defined $text && !ref $text;
  return { answer => $text };
}

=func answer

    answer('The answer is 42.')

The reaction "reply with this text": C<< { answer => $text } >>.

=cut

sub tool {
  my ( $name, $arguments ) = @_;
  croak __PACKAGE__.'::tool needs a tool name' unless defined $name && !ref $name && length $name;
  $arguments //= {};
  croak __PACKAGE__.'::tool arguments must be a HashRef' unless ref $arguments eq 'HASH';
  return { tool_calls => [ [ $name, $arguments ] ] };
}

=func tool

    tool( read_file => { path => 'a.txt' } )

The reaction "call this tool with these arguments":
C<< { tool_calls => [ [ $name, \%arguments ] ] } >>. The arguments default to
C<{}>.

=cut

sub tools {
  my ( $calls ) = @_;
  croak __PACKAGE__.'::tools needs an ArrayRef of calls' unless ref $calls eq 'ARRAY' && @$calls;
  my @tool_calls;
  for my $call (@$calls) {
    if ( ref $call eq 'ARRAY' ) {
      push @tool_calls, @{ tool(@$call)->{tool_calls} };
    }
    elsif ( ref $call eq 'HASH' && ref $call->{tool_calls} eq 'ARRAY' ) {
      push @tool_calls, @{ $call->{tool_calls} };
    }
    else {
      croak __PACKAGE__.'::tools takes [ $name, \%arguments ] pairs or tool(...) reactions';
    }
  }
  return { tool_calls => \@tool_calls };
}

=func tools

    tools( [ [ read_file => { path => 'a.txt' } ], [ bash => { command => 'ls' } ] ] )
    tools( [ tool( read_file => { path => 'a.txt' } ), tool( bash => { command => 'ls' } ) ] )

The reaction "call these tools in one turn", in order. Each element is a
C<[ $name, \%arguments ]> pair or a L</tool> reaction.

=cut

sub error {
  my ( $status, $message ) = @_;
  croak __PACKAGE__.'::error needs an HTTP status from 400 to 599'
    unless defined $status && !ref $status && $status =~ /\A[45]\d\d\z/;
  croak __PACKAGE__.'::error needs a message' unless defined $message && !ref $message;
  return { error => { status => 0 + $status, message => $message } };
}

=func error

    error( 429, 'Rate limit reached' )

The reaction "fail like a server that answers with this status and message":
C<< { error => { status => 429, message => '...' } } >>. The status is an
HTTP error status (400 to 599). The caller sees its usual error path: a
C<croak> from C<simple_chat>, a failed future from the C<_f> calls.

=cut

my %AFTER_KEYS = map { $_ => 1 } qw( tool result );

sub after {
  my ( @args ) = @_;
  my %match = @args == 1 ? ( tool => $args[0] ) : @args % 2 ? () : @args;
  croak __PACKAGE__.'::after takes a tool name, or tool => ... and result => ...; '
    .'it is a trigger: write after(...) => $reaction'
    if ( @args > 1 && @args % 2 ) || grep { !$AFTER_KEYS{$_} } keys %match;
  for my $key ( keys %match ) {
    my $value = $match{$key};
    croak __PACKAGE__."::after $key must be a string or a Regexp"
      if defined $value && ref $value && ref $value ne 'Regexp';
  }
  return { after => \%match };
}

=func after

    after()                                        # after any tool result
    after('read_file')                             # after a read_file result
    after( tool => qr/_file\z/ )                   # tool name matches
    after( tool => 'bash', result => qr/Exit code: (\d+)/ )

The trigger "the last message is a tool result" - it goes on the left of a
rule, C<< after('read_file') => answer('Done.') >>. C<tool> is the tool's
name: a string is compared exactly, a C<Regexp> is matched, and without it any
tool counts. C<result> does the same against the result's text. The captures
of the C<Regexp>s (the tool's first, then the result's) are passed to a
C<sub> reaction. Returns C<< { after => { tool => ..., result => ... } } >>.

=cut

=seealso

=over

=item * L<Langertha::Engine::Virtual> - The engine these rules drive, and the rule language

=back

=cut

1;
