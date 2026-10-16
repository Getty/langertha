package Langertha::Engine::Virtual;
# ABSTRACT: Rule-driven engine that answers without network, key or model
our $VERSION = '0.504';
use Moose;
use Carp qw( croak );
use Encode ();
use HTTP::Response;
use LWP::UserAgent;
use Module::Runtime qw( use_module );
use Path::Tiny;
use Scalar::Util qw( weaken );
use YAML::PP;
use Langertha::Request::SyncHTTP;
use Langertha::Virtual::Rules ();

extends 'Langertha::Engine::Remote';

# Chat and the tool loop run through the real OpenAI-dialect request builder
# and parser (OpenAICompatible + OpenAPI); only the transport is replaced by
# the in-process rule evaluation below. No Streaming, Temperature,
# ResponseFormat, ...: the engine claims only what it serves.
with map { 'Langertha::Role::'.$_ } qw(
  OpenAICompatible
  OpenAPI
  Models
  ResponseSize
  SystemPrompt
  Chat
  Tools
);

=head1 SYNOPSIS

    use Langertha::Engine::Virtual;
    use Langertha::Virtual::Rules qw( answer tool after );

    my $engine = Langertha::Engine::Virtual->new(
      rules => [
        'Hello'               => answer('Hi there!'),
        qr/\AAdd (\d+) and (\d+)\z/ => sub {
          my ( $request, $first, $second ) = @_;
          return tool( add => { a => $first, b => $second } );
        },
        after('add')          => sub {
          my ( $request ) = @_;
          return answer( 'The sum is '.$request->{tool_results}[0]{content} );
        },
      ],
      fallback => answer('I only know a few prompts.'),
    );

    print $engine->simple_chat('Hello');            # Hi there!

    # The MCP tool loop runs as with any engine
    my $tooled = Langertha::Engine::Virtual->new(
      rules       => $engine->rules,
      fallback    => $engine->fallback,
      mcp_servers => [ $mcp ],
    );
    my $text = await $tooled->chat_with_tools_f('Add 7 and 15');   # The sum is 22

    # One reply per request, in order
    my $scripted = Langertha::Engine::Virtual->new(
      script => [ tool( read_file => { path => 'a.txt' } ), answer('Done.') ],
    );

    # Ready-made rule sets
    my $echo  = Langertha::Engine::Virtual->preset('echo');
    my $files = Langertha::Engine::Virtual->preset( files => mcp_servers => [ $mcp ] );

    # Rules from a YAML file
    my $from_file = Langertha::Engine::Virtual->new( rules_file => 't/data/rules.yml' );

    # What happened
    $engine->requests;   # every request the engine answered, as seen by the rules
    $engine->calls;      # every tool call it emitted: [ $name, \%arguments ]
    $engine->results;    # every tool result the tool loop handed back

=head1 DESCRIPTION

An engine that needs no network, no API key and no model: it answers each
request by L</RULES> you give it (or by a L</script>), so a test, a demo or a
manual run gets exactly the replies it asks for. Everything above the
transport is the real thing: requests are built by
L<Langertha::Role::OpenAICompatible>, replies are parsed into
L<Langertha::Response> by the same code that reads OpenAI, and
L<Langertha::Role::Tools/chat_with_tools_f> (or another tool loop, such as
langertha-raider's) runs the tools of its L<Langertha::Role::Tools/mcp_servers>
for real. Only the HTTP round trip is replaced: the request never leaves the
process; the engine reads it, picks a reaction and answers it as an OpenAI
chat completion. That holds for the chat traffic only: if
C<LANGFUSE_PUBLIC_KEY> and C<LANGFUSE_SECRET_KEY> are set in the environment,
an explicit C<langfuse_flush> can still send traces over the network. Pass
C<< langfuse_enabled => 0 >> to keep a test or demo fully offline. Synchronous (C<simple_chat>) and C<_f> calls both work; the
C<_f> calls run synchronously (their futures are already complete), and
L<Langertha::Role::AsyncHTTP/async_loop> is C<undef>. The in-process
transport is the engine's own C<user_agent> (and the C<_async_http> built
over it); passing either to the constructor replaces it.

The engine supports chat and tool calling (C<chat>, C<tools_native>, the
C<tool_choice_*> flags, C<parallel_tool_use>, C<response_size>,
C<system_prompt>). There is no streaming, no embedding, no transcription and
no image generation. Request parameters it has no use for (C<tool_choice>, a
C<response_format>, C<max_tokens>, ...) are accepted and visible in
L</requests>, but do not change the reaction.

L<Langertha::Engine::Mock> is the same engine under the name C<Mock>.

=head1 RULES

C<rules> is a list of C<< TRIGGER => REACTION >> pairs, checked in order for
every request; the first pair whose trigger matches gives the reaction. When
none matches, L</fallback> answers. Without a fallback the request fails
like a request to a server that answers with an error, here
C<< 500 No Reaction >>: C<simple_chat> croaks and the C<_f> calls fail with
C<< <class> request failed: 500 No Reaction - no rule matches and no fallback
is set (request N, last message: ...) >>, so a missing rule is never a silent
answer. A C<sub> reaction that dies, or returns something that is not a
reaction, fails the request the same way with C<500 Reaction Failed> and the
error.

=head2 Triggers

String and C<Regexp> triggers are matched against the text of the B<last
message, if it is a user message>. The text of a message whose content is a
list of parts is its text parts joined with a newline.

=over

=item * a B<string> matches when it is exactly equal to that text - no
trimming, no case folding.

=item * a B<Regexp> matches as C<=~> does. Its captures are passed to a
C<sub> reaction after the request.

=item * a B<sub> is a predicate: it is called with the request (see L</The
request>) and matches when it returns true. It is checked for every request,
whatever the last message is.

=item * an L<after|Langertha::Virtual::Rules/after> trigger matches when the
last message is a tool result: C<after('read_file')> for a C<read_file>
result, C<after()> for any tool, C<< after( tool => qr/.../, result => qr/.../ ) >>
to match the tool name and the result text. With several results at the end
of the conversation (parallel calls) the first one that matches counts.
Captures of its C<Regexp>s are passed to a C<sub> reaction, the tool name's
first.

=back

So a string or C<Regexp> rule fires on the user's prompt but not again when
the tool loop comes back with the result of the call it asked for; that turn
is answered by an C<after> rule, a predicate or the fallback.

=head2 Reactions

=over

=item * C<< answer($text) >> (C<< { answer => $text } >>): reply with this text.

=item * C<< tool( $name => \%arguments ) >>
(C<< { tool_calls => [ [ $name, \%arguments ] ] } >>): call this tool.

=item * C<< tools( [ [ $name => \%arguments ], ... ] ) >>: call several tools
in one turn.

=item * a plain string: the same as C<answer> of it.

=item * a HashRef with C<answer> (or its alias C<text>) and C<tool_calls>
together: a reply that carries text and calls.

=item * a B<sub>: called with the request and the captures of the trigger,
C<< $sub->( $request, @captures ) >>; it returns one of the above (not
another sub).

=back

The helpers live in L<Langertha::Virtual::Rules>. Rules and reactions are
checked when the engine is built: a malformed one croaks there, not on the
first request. Every emitted tool call gets a unique id
(C<call_virtual_1>, C<call_virtual_2>, ...) and the reply's C<finish_reason>
is C<tool_calls>; a reply without calls finishes with C<stop>.

=head2 The request

Sub triggers and sub reactions get the request as a HashRef:

=over

=item * C<text> - the text of the last message when it is a user message, else C<undef>

=item * C<last_user_text> - the text of the most recent user message anywhere in the conversation

=item * C<tool_results> - the tool results at the end of the conversation, in order, each C<< { id, name, content } >> (C<content> is the result's text, C<name> the tool name of the call it answers)

=item * C<messages> - the conversation as sent (OpenAI chat format)

=item * C<tools> - the tool definitions sent with the request (OpenAI format), or C<[]>

=item * C<model> - the model the request named

=item * C<number> - the request's number, from 1

=item * C<body> - the whole decoded request body

=back

=head2 Script mode

With C<script> instead of C<rules>, the engine answers the first request with
the first reaction, the second with the second, and so on, whatever they
contain. Entries are reactions as above; a sub entry gets the request. When
the script runs out, L</fallback> answers, or the request fails with
C<500 No Reaction> (C<the script has run out ...>). C<script> and C<rules>
cannot be combined.

=head2 Rules files

L</rules_file> loads the rules from YAML, which cannot hold subs or
C<Regexp>s:

    rules:                     # trigger text => reaction, matched exactly
      Write a note.:
        tool_calls:
          - [ write_file, { path: notes/a.txt, content: "hello\n" } ]
      Hello: { answer: Hi there! }
    after:                     # tool name => reaction
      write_file: { answer: Fertig. }
    fallback: { answer: done }

or, for script mode, C<script:> with a list of reactions:

    script:
      - tool_calls:
          - [ read_file, { path: app.txt } ]
      - text: Done.

A reaction is C<< { answer: ... } >> (or C<< { text: ... } >>),
C<< { tool_calls: [ [ name, { arguments } ], ... ] } >>, both, or a plain
string. The keys C<rules>, C<after>, C<fallback> and C<script> are the only
ones allowed; anything else croaks. C<after> rules come after the C<rules>
ones. A key the file sets cannot also be passed to the constructor.

The keys of C<rules> and C<after> are read by YAML before they are texts: a
trigger that YAML takes for a boolean, null or number (C<true>, C<null>, C<~>,
C<1.0>, C<0x10>) must be quoted, else the rule never matches the prompt. The
entries of each map are taken in alphabetical order of their keys, not file
order, so C<after> rules too: when several match one tool result, the first in
that order wins.

=head1 PRESETS

L</preset> builds an engine with a ready-made rule set. These are the
prompts that trigger them, exactly as written:

=head2 echo

Answers every request with the text of the most recent user message,
unchanged. Every prompt triggers it.

=head2 files

Drives the file tools of an MCP server such as langertha-raider's stock
C<files> and C<bash> tools (C<read_file>, C<write_file>, C<bash>). C<PATH>
is one word without spaces; C<CONTENT> and C<COMMAND> run to the end of the
prompt, newlines included. The words around them must match exactly:

=over

=item * C<Read the file PATH> - calls C<read_file> with C<< { path => PATH } >>

=item * C<Write the file PATH: CONTENT> - calls C<write_file> with
C<< { path => PATH, content => CONTENT } >>

=item * C<Run the command COMMAND> - calls C<bash> with C<< { command => COMMAND } >>

=back

After any tool result it answers with the result's text (several results
joined with a newline). Any other prompt is answered with a short list of
these prompts.

=head1 ATTRIBUTES AND METHODS

Besides the chat and tool-calling API every engine has
(L<Langertha::Role::Chat>, L<Langertha::Role::Tools>), the engine has the
following. L</requests>, L</calls> and L</results> keep what the engine saw
and did, in order, for a test to check; they are for reading.

=cut

has '+url' => (
  default => 'http://virtual.invalid/v1',
);

=attr url

The URL the requests are addressed to. Defaults to
C<http://virtual.invalid/v1>; nothing is ever sent there (the C<.invalid>
top-level domain cannot resolve).

=cut

sub default_model { 'virtual' }

=method default_model

C<virtual>. Any C<model> may be passed; it is sent in the request and comes
back as L<Langertha::Response/model>.

=cut

sub api_key_env { undef }

=method api_key_env

C<undef>: the engine reads no API key.

=cut

sub _build_openapi_operations {
  return use_module('Langertha::Spec::OpenAI')->data;
}

has rules => (
  is      => 'ro',
  isa     => 'ArrayRef',
  default => sub { [] },
);

=attr rules

    rules => [ 'Hello' => answer('Hi'), qr/\ABye/ => 'Bye!', after('ls') => answer('ok') ]

The rules, as C<< TRIGGER => REACTION >> pairs (see L</RULES>). Defaults to
C<[]>.

=cut

has fallback => (
  is        => 'ro',
  predicate => 'has_fallback',
);

=attr fallback

    fallback => answer('I do not know.')

The reaction for a request no rule matches, or that comes after the end of
the L</script>. Without one, such a request fails with C<500 No Reaction>.

=cut

has script => (
  is        => 'ro',
  isa       => 'ArrayRef',
  predicate => 'has_script',
);

=attr script

    script => [ tool( ls => {} ), answer('Done.') ]

Script mode (see L</Script mode>): one reaction per request, in order. Cannot
be combined with L</rules>.

=cut

has rules_file => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_rules_file',
);

=attr rules_file

    rules_file => 't/data/virtual_rules.yml'

A YAML file with C<rules>, C<after>, C<fallback> and/or C<script> (see
L</Rules files>), read when the engine is built.

=cut

has requests => (
  is       => 'ro',
  isa      => 'ArrayRef',
  init_arg => undef,
  default  => sub { [] },
);

=attr requests

Every chat request the engine received, in order, including the ones that
failed (no rule matched, a reaction died), as the HashRef the rules saw (see
L</The request>).

=cut

has calls => (
  is       => 'ro',
  isa      => 'ArrayRef',
  init_arg => undef,
  default  => sub { [] },
);

=attr calls

Every tool call the engine emitted, in order, as C<[ $name, \%arguments ]>.

=cut

has results => (
  is       => 'ro',
  isa      => 'ArrayRef',
  init_arg => undef,
  default  => sub { [] },
);

=attr results

Every tool result a tool loop handed back through
L<Langertha::Role::Tools/format_tool_results>, in order, as the loop passed
it: C<< { tool_call => ..., result => \%mcp_result } >>, where C<result> is
the MCP C<call_tool> result (C<content>, C<isError>, ...).

=cut

has _script_position => (
  is       => 'rw',
  isa      => 'Int',
  init_arg => undef,
  default  => 0,
);

my %RULES_FILE_KEYS = map { $_ => 1 } qw( rules after fallback script );
my %REACTION_KEYS   = map { $_ => 1 } qw( answer text tool_calls );
my %PRESETS         = (
  echo  => '_preset_echo',
  files => '_preset_files',
);

around BUILDARGS => sub {
  my ( $orig, $class, @args ) = @_;
  my $args = $class->$orig(@args);
  return $args unless defined $args->{rules_file};
  my $file = $args->{rules_file} = "$args->{rules_file}";
  my $loaded = $class->_load_rules_file($file);
  for my $key ( sort keys %$loaded ) {
    croak $class.": $key is given to the constructor and in rules_file $file" if exists $args->{$key};
    $args->{$key} = $loaded->{$key};
  }
  return $args;
};

sub BUILD {
  my ( $self ) = @_;
  my $class = ref $self;
  my @rules = @{ $self->rules };
  croak $class.': rules must be a list of TRIGGER => REACTION pairs (odd number of elements)' if @rules % 2;
  croak $class.': rules and script cannot be combined' if @rules && $self->has_script;
  my $number = 0;
  while ( my ( $trigger, $reaction ) = splice @rules, 0, 2 ) {
    $number++;
    $self->_check_trigger( $trigger, "rule $number" );
    $self->_check_reaction( $reaction, "rule $number" );
  }
  if ( $self->has_script ) {
    my $position = 0;
    $self->_check_reaction( $_, 'script entry '.++$position ) for @{ $self->script };
  }
  $self->_check_reaction( $self->fallback, 'fallback' ) if $self->has_fallback;
  return;
}

sub _check_trigger {
  my ( $self, $trigger, $where ) = @_;
  my $class = ref $self;
  croak $class.": the trigger of $where is undef" unless defined $trigger;
  return if !ref $trigger || ref $trigger eq 'Regexp' || ref $trigger eq 'CODE';
  return if ref $trigger eq 'HASH' && keys %$trigger == 1 && ref $trigger->{after} eq 'HASH';
  croak $class.": the trigger of $where must be a string, a Regexp, a sub or after(...)";
}

sub _check_reaction {
  my ( $self, $reaction, $where ) = @_;
  return if ref $reaction eq 'CODE';
  $self->_normalize_reaction( $reaction, $where );
  return;
}

# A reaction as data: { answer => Maybe[Str], tool_calls => [ [ $name, \%arguments ], ... ] }.
sub _normalize_reaction {
  my ( $self, $reaction, $where ) = @_;
  my $class = ref $self;
  return { answer => $reaction, tool_calls => [] } if defined $reaction && !ref $reaction;
  croak $class.": $where must be a text, a HashRef or a sub, not ".( defined $reaction ? ref $reaction : 'undef' )
    unless ref $reaction eq 'HASH';
  my @unknown = grep { !$REACTION_KEYS{$_} } sort keys %$reaction;
  croak $class.": $where has unknown keys: @unknown (known: answer, text, tool_calls)" if @unknown;
  croak $class.": $where has both answer and text" if exists $reaction->{answer} && exists $reaction->{text};
  my $answer = exists $reaction->{answer} ? $reaction->{answer} : $reaction->{text};
  croak $class.": the answer of $where must be a text" if ref $answer;
  my $calls = $reaction->{tool_calls} // [];
  croak $class.": the tool_calls of $where must be an ArrayRef" unless ref $calls eq 'ARRAY';
  my @tool_calls;
  for my $call (@$calls) {
    croak $class.": each tool call of $where must be [ \$name, \\%arguments ]"
      unless ref $call eq 'ARRAY' && @$call >= 1 && @$call <= 2
        && defined $call->[0] && !ref $call->[0] && length $call->[0]
        && ( !defined $call->[1] || ref $call->[1] eq 'HASH' );
    push @tool_calls, [ $call->[0], $call->[1] // {} ];
  }
  croak $class.": $where has neither an answer nor tool calls" unless defined $answer || @tool_calls;
  return { answer => $answer, tool_calls => \@tool_calls };
}

sub _load_rules_file {
  my ( $class, $file ) = @_;
  my $data = YAML::PP->new( boolean => 'JSON::PP' )->load_string( path($file)->slurp_utf8 );
  croak $class.": rules_file $file must hold a mapping" unless ref $data eq 'HASH';
  my @unknown = grep { !$RULES_FILE_KEYS{$_} } sort keys %$data;
  croak $class.": rules_file $file has unknown keys: @unknown (known: after, fallback, rules, script)" if @unknown;
  my %args;
  for my $key (qw( rules after )) {
    next unless exists $data->{$key};
    my $map = $data->{$key};
    croak $class.": $key in rules_file $file must be a mapping" unless ref $map eq 'HASH';
    push @{ $args{rules} }, map {
      ( $key eq 'after' ? Langertha::Virtual::Rules::after($_) : $_ ) => $map->{$_}
    } sort keys %$map;
  }
  $args{fallback} = $data->{fallback} if exists $data->{fallback};
  $args{script}   = $data->{script}   if exists $data->{script};
  return \%args;
}

sub preset {
  my ( $class, $name, @args ) = @_;
  my $method = defined $name ? $PRESETS{$name} : undef;
  croak $class.'->preset: unknown preset '.( $name // 'undef' ).' (known: '.join( ', ', sort keys %PRESETS ).')'
    unless $method;
  return $class->new( $class->$method, @args );
}

=method preset

    my $engine = Langertha::Engine::Virtual->preset('echo');
    my $engine = Langertha::Engine::Virtual->preset( files => mcp_servers => [ $mcp ] );

Class method. Builds an engine with the named rule set (see L</PRESETS>);
further arguments go to the constructor and replace the preset's own
C<rules> or C<fallback> when they name them. Combined with C<rules_file>,
C<preset> croaks, because the preset's C<rules> and the file's collide. Croaks
on an unknown name.

=cut

sub _preset_echo {
  return (
    fallback => sub {
      my ( $request ) = @_;
      return Langertha::Virtual::Rules::answer( $request->{last_user_text} // '' );
    },
  );
}

sub _preset_files {
  return (
    rules => [
      qr/\ARead the file (\S+)\z/ => sub {
        my ( $request, $path ) = @_;
        return Langertha::Virtual::Rules::tool( read_file => { path => $path } );
      },
      qr/\AWrite the file (\S+): (.*)\z/s => sub {
        my ( $request, $path, $content ) = @_;
        return Langertha::Virtual::Rules::tool( write_file => { path => $path, content => $content } );
      },
      qr/\ARun the command (.+)\z/s => sub {
        my ( $request, $command ) = @_;
        return Langertha::Virtual::Rules::tool( bash => { command => $command } );
      },
      Langertha::Virtual::Rules::after() => sub {
        my ( $request ) = @_;
        return Langertha::Virtual::Rules::answer(
          join "\n", map { $_->{content} // '' } @{ $request->{tool_results} } );
      },
    ],
    fallback => Langertha::Virtual::Rules::answer(
      "I know these prompts:\nRead the file PATH\nWrite the file PATH: CONTENT\nRun the command COMMAND" ),
  );
}

sub list_models {
  my ( $self, %opts ) = @_;
  my @models = ( { id => $self->model } );
  return $opts{full} ? \@models : [ map { $_->{id} } @models ];
}

=method list_models

    my $ids = $engine->list_models;   # [ 'virtual' ]

The configured L<Langertha::Role::Models/model>, without a request.

=cut

# The transport. Every request the sync user agent sends is answered by the
# request_send handler before LWP picks a protocol, and the _f calls run over
# the same agent through the sync shim, so nothing ever reaches the network.
sub _build_user_agent {
  my ( $self ) = @_;
  my $ua = LWP::UserAgent->new( agent => $self->user_agent_agent );
  my $engine = $self;
  weaken $engine;
  $ua->add_handler( request_send => sub {
    my ( $request ) = @_;
    return $engine->_virtual_response($request);
  } );
  return $ua;
}

sub _build__async_http {
  my ( $self ) = @_;
  return Langertha::Request::SyncHTTP->new( user_agent => $self->user_agent );
}

around format_tool_results => sub {
  my ( $orig, $self, $data, $results ) = @_;
  push @{ $self->results }, @{ $results // [] };
  return $self->$orig( $data, $results );
};

# A request the engine cannot answer comes back as an error status, so the
# caller fails with core's own "<class> request failed: <status> - <reason>"
# on every path (sync, _f, the tool loops), as with a real server.
sub _virtual_response {
  my ( $self, $request ) = @_;
  unless ( uc( $request->method ) eq 'POST' && $request->uri->path =~ m{/chat/completions\z} ) {
    return $self->_virtual_http_response( $request, 404, 'Not Found',
      'answers only chat completions, not '.$request->method.' '.$request->uri->path );
  }
  my $view = $self->_request_view( $self->json->decode( $request->content ) );
  push @{ $self->requests }, $view;
  my ( $reaction, $error );
  eval { $reaction = $self->_reaction_for($view); 1 } or $error = $@ || 'unknown error';
  if ( defined $error ) {
    $error =~ s/\s+\z//;
    return $self->_virtual_http_response( $request, 500, 'Reaction Failed', $error );
  }
  return $self->_virtual_http_response( $request, 500, 'No Reaction', $self->_no_reaction_message($view) )
    unless $reaction;
  return $self->_virtual_http_response( $request, 200, 'OK', $self->_completion( $view, $reaction ) );
}

# $content is a completion body (JSON) or an error text (text/plain).
sub _virtual_http_response {
  my ( $self, $request, $code, $message, $content ) = @_;
  my $response = ref $content
    ? HTTP::Response->new( $code, $message, [ 'Content-Type' => 'application/json' ], $self->json->encode($content) )
    : HTTP::Response->new( $code, $message, [ 'Content-Type' => 'text/plain; charset=utf-8' ], Encode::encode( 'UTF-8', $content ) );
  $response->request($request);
  return $response;
}

# What the rules see of a request (documented under "The request").
sub _request_view {
  my ( $self, $body ) = @_;
  my @messages = @{ $body->{messages} // [] };
  my $last_role = @messages ? $messages[-1]{role} // '' : '';
  my ($last_user) = grep { ( $_->{role} // '' ) eq 'user' } reverse @messages;
  my %tool_names = map { ( $_->{id} // '' ) => $_->{function}{name} }
    map { @{ $_->{tool_calls} // [] } }
    grep { ( $_->{role} // '' ) eq 'assistant' } @messages;
  my @results;
  my $index = $#messages;
  while ( $index >= 0 && ( $messages[$index]{role} // '' ) eq 'tool' ) {
    unshift @results, $messages[ $index-- ];
  }
  return {
    number         => scalar @{ $self->requests } + 1,
    model          => $body->{model},
    messages       => \@messages,
    text           => $last_role eq 'user' ? $self->_message_text( $messages[-1] ) : undef,
    last_user_text => $last_user ? $self->_message_text($last_user) : undef,
    tool_results   => [ map { {
      id      => $_->{tool_call_id},
      name    => $tool_names{ $_->{tool_call_id} // '' },
      content => $self->_message_text($_),
    } } @results ],
    tools          => $body->{tools} // [],
    body           => $body,
  };
}

sub _message_text {
  my ( $self, $message ) = @_;
  my $content = $message->{content};
  return $content // '' unless ref $content eq 'ARRAY';
  return join "\n", map { ref $_ ? $_->{text} // () : $_ // () }
    grep { !ref $_ || ( ref $_ eq 'HASH' && ( $_->{type} // '' ) eq 'text' ) } @$content;
}

sub _reaction_for {
  my ( $self, $view ) = @_;
  if ( $self->has_script ) {
    my $position = $self->_script_position;
    if ( $position < @{ $self->script } ) {
      $self->_script_position( $position + 1 );
      return $self->_resolve_reaction( $self->script->[$position], $view, [], 'script entry '.( $position + 1 ) );
    }
  }
  else {
    my @rules  = @{ $self->rules };
    my $number = 0;
    while ( my ( $trigger, $reaction ) = splice @rules, 0, 2 ) {
      $number++;
      my $captures = $self->_match_trigger( $trigger, $view ) or next;
      return $self->_resolve_reaction( $reaction, $view, $captures, "rule $number" );
    }
  }
  return $self->_resolve_reaction( $self->fallback, $view, [], 'fallback' ) if $self->has_fallback;
  return;
}

sub _no_reaction_message {
  my ( $self, $view ) = @_;
  my $what = $self->has_script ? 'the script has run out' : 'no rule matches';
  my $last = defined $view->{text} ? "the user message '$view->{text}'"
    : @{ $view->{tool_results} } ? 'the tool result of '
      .join( ', ', map { $_->{name} // 'an unknown call' } @{ $view->{tool_results} } )
    : 'a conversation that does not end in a user message or a tool result';
  return $what.' and no fallback is set (request '.$view->{number}.", last message: $last)";
}

# Captures (an ArrayRef, empty for none) when the trigger matches, else undef.
sub _match_trigger {
  my ( $self, $trigger, $view ) = @_;
  return $self->_match_after( $trigger->{after}, $view ) if ref $trigger eq 'HASH';
  return $trigger->($view) ? [] : undef if ref $trigger eq 'CODE';
  return undef unless defined $view->{text};
  return $self->_match_value( $trigger, $view->{text} );
}

sub _match_after {
  my ( $self, $match, $view ) = @_;
  for my $result ( @{ $view->{tool_results} } ) {
    my $tool = $self->_match_value( $match->{tool}, $result->{name} ) or next;
    my $text = $self->_match_value( $match->{result}, $result->{content} ) or next;
    return [ @$tool, @$text ];
  }
  return undef;
}

# A string matcher compares exactly, a Regexp matches; undef matches anything.
sub _match_value {
  my ( $self, $matcher, $value ) = @_;
  return [] unless defined $matcher;
  return undef unless defined $value;
  return $value eq $matcher ? [] : undef unless ref $matcher;
  my @captures = $value =~ $matcher or return undef;
  return $#+ ? \@captures : [];
}

sub _resolve_reaction {
  my ( $self, $reaction, $view, $captures, $where ) = @_;
  if ( ref $reaction eq 'CODE' ) {
    $reaction = $reaction->( $view, @$captures );
    croak ref($self).": the sub of $where returned a sub, not a reaction" if ref $reaction eq 'CODE';
    $where = "the reply of the sub of $where";
  }
  return $self->_normalize_reaction( $reaction, $where );
}

# The reaction as an OpenAI chat completion body.
sub _completion {
  my ( $self, $view, $reaction ) = @_;
  my @tool_calls = map {
    my ( $name, $arguments ) = @$_;
    push @{ $self->calls }, [ $name, $arguments ];
    {
      id       => 'call_virtual_'.scalar @{ $self->calls },
      type     => 'function',
      function => { name => $name, arguments => $self->encode_json_text($arguments) },
    };
  } @{ $reaction->{tool_calls} };
  return {
    id      => 'virtual-'.$view->{number},
    object  => 'chat.completion',
    created => time,
    model   => $view->{model} // $self->chat_model,
    choices => [ {
      index         => 0,
      message       => {
        role    => 'assistant',
        content => $reaction->{answer},
        @tool_calls ? ( tool_calls => \@tool_calls ) : (),
      },
      finish_reason => @tool_calls ? 'tool_calls' : 'stop',
    } ],
  };
}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Virtual::Rules> - C<answer>, C<tool>, C<tools> and C<after>

=item * L<Langertha::Engine::Mock> - The same engine under the name C<Mock>

=item * L<Langertha::Role::Tools> - The MCP tool loop the engine runs in

=item * L<Langertha::Role::OpenAICompatible> - The request builder and parser it reuses

=back

=cut

1;
