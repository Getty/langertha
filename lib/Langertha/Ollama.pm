package Langertha::Ollama;

use Moose;
use File::ShareDir::ProjectDistDir qw( :all );

with qw( Langertha::Role::OpenAPI );

sub openapi_file { yaml => dist_file('Langertha','ollama.yaml') };

1;
