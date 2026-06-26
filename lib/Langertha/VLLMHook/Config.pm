package Langertha::VLLMHook::Config;
# ABSTRACT: Loader for vLLM-Hook model_configs/*.json files
our $VERSION = '0.503';
use Moose;
use Carp qw( croak );
use JSON::MaybeXS ();

with 'Langertha::Role::JSON';

=head1 SYNOPSIS

    use Langertha::VLLMHook::Config;
    use Langertha::Engine::VLLMHook;

    my $cfg = Langertha::VLLMHook::Config->new(
        file => 'model_configs/hidden_states/Qwen2.5-3B-Instruct.json',
    );

    my $engine = Langertha::Engine::VLLMHook->new(
        url        => 'http://localhost:8770/v1',
        vllm_xargs => $cfg->xargs,
    );

=head1 DESCRIPTION

Parses the JSON model configuration files shipped with vLLM-Hook
(L<https://github.com/IBM/vLLM-Hook>) and turns them into the C<vllm_xargs>
HashRef that L<Langertha::Engine::VLLMHook> sends on the wire.

Three config shapes are recognised, mirroring vLLM-Hook's own
C<HookClient._load_config> / C<_build_extra_body>:

=over 4

=item * B<Attention tracker / CoRer> — has C<params.important_heads> (and
optionally C<hookq.hookq_mode>). Maps to worker C<qk>, emitting C<output_qk>.

=item * B<Hidden states> — has a top-level C<hidden_states> block. Maps to
worker C<hidden_states>, emitting C<output_hidden_states>.

=item * B<Activation steering> — has a top-level C<steering> block. Maps to
worker C<steer>, emitting C<steer>.

=back

Nested values in the produced C<xargs> are already JSON-encoded as strings,
because vLLM's C<vllm_xargs> only accepts scalar values — so the result can be
handed straight to L<Langertha::Engine::VLLMHook/vllm_xargs>.

=cut

has file => (
  is        => 'ro',
  isa       => 'Str',
  predicate => 'has_file',
);

=attr file

Path to a vLLM-Hook C<model_configs/*.json> file. Either C<file> or C<data>
must be supplied. When C<file> is set, C<data> is loaded from it lazily.

=cut

has data => (
  is         => 'ro',
  isa        => 'HashRef',
  lazy_build => 1,
);
sub _build_data {
  my ( $self ) = @_;
  croak "Langertha::VLLMHook::Config requires 'file' or 'data'"
    unless $self->has_file;
  open my $fh, '<:raw', $self->file
    or croak "Langertha::VLLMHook::Config cannot open '".$self->file."': $!";
  local $/;
  my $content = <$fh>;
  close $fh;
  return $self->json->decode($content);
}

=attr data

The parsed config as a HashRef. Built from C<file> when not supplied directly.
Pass C<data> explicitly to construct a config from an in-memory structure
(useful for tests).

=cut

=method worker

    my $worker = $cfg->worker;   # 'qk' | 'hidden_states' | 'steer' | undef

Returns the vLLM-Hook worker name implied by the config (the value you would
set as C<VLLM_HOOK_WORKER> when starting C<vllm serve>). Determined from the
structural keys present, falling back to C<model_info.provider>. Returns
C<undef> when the shape is not recognised.

=cut

sub worker {
  my ( $self ) = @_;
  my $cfg = $self->data;
  return 'steer'          if ref $cfg->{steering} eq 'HASH';
  return 'hidden_states'  if ref $cfg->{hidden_states} eq 'HASH';
  return 'qk'             if ref $cfg->{params} eq 'HASH'
                          && exists $cfg->{params}{important_heads};
  my $provider = $cfg->{model_info} ? ( $cfg->{model_info}{provider} // '' ) : '';
  return 'qk' if $provider =~ /attn/;
  return undef;
}

=method model_id

    my $id = $cfg->model_id;

Returns C<model_info.model_id> from the config, or C<undef> when absent.

=cut

sub model_id {
  my ( $self ) = @_;
  my $info = $self->data->{model_info} or return undef;
  return $info->{model_id};
}

=method xargs

    my $xargs = $cfg->xargs;

Returns the C<vllm_xargs> HashRef ready for L<Langertha::Engine::VLLMHook>.
Nested values (the layer/heads map, the layers list, the full steering dict)
are returned as JSON strings, since C<vllm_xargs> only carries scalars. Returns
an empty HashRef for an unrecognised config.

=cut

sub xargs {
  my ( $self ) = @_;
  my $cfg = $self->data;

  if ( ref $cfg->{steering} eq 'HASH' ) {
    return { steer => $self->json->encode( $cfg->{steering} ) };
  }

  if ( ref $cfg->{hidden_states} eq 'HASH' ) {
    my $layers = $cfg->{hidden_states}{layers};
    if ( ref $layers eq 'ARRAY' && @$layers ) {
      return { output_hidden_states => $self->json->encode($layers) };
    }
    return { output_hidden_states => JSON::MaybeXS::true() };
  }

  if ( ref $cfg->{params} eq 'HASH' && $cfg->{params}{important_heads} ) {
    my %layer_to_heads;
    for my $pair ( @{ $cfg->{params}{important_heads} } ) {
      my ( $layer, $head ) = @$pair;
      push @{ $layer_to_heads{$layer} }, $head;
    }
    my $mode = $cfg->{hookq} ? ( $cfg->{hookq}{hookq_mode} // 'last_token' ) : 'last_token';
    return {
      output_qk  => $self->json->encode( \%layer_to_heads ),
      hookq_mode => $mode,
    };
  }

  return {};
}

__PACKAGE__->meta->make_immutable;

=seealso

=over

=item * L<Langertha::Engine::VLLMHook> - Engine that consumes this config

=item * L<https://github.com/IBM/vLLM-Hook> - vLLM-Hook plugin

=item * L<Langertha::Role::JSON> - Provides the JSON encoder used here

=back

=cut

1;
