package Langertha::Spec::LMStudio;
# ABSTRACT: Pre-computed OpenAPI operations for LM Studio native API
our $VERSION = '0.403';

# AUTO-GENERATED style table (maintained in-repo).
# Source: share/lmstudio.yaml (2 operations)

my $DATA;

sub data {
  $DATA //= {
    server_url => 'http://localhost:1234',
    operations => {
      'chat' => { method => 'POST', path => '/api/v1/chat', content_type => 'application/json' },
      'listModels' => { method => 'GET', path => '/api/v1/models' },
    },
  };
  return $DATA;
}

1;
