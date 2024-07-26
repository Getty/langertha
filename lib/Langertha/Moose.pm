package Langertha::Moose;

use Moose ();
use Moose::Exporter;
 
Moose::Exporter->setup_import_methods(
  with_meta => [],
  as_is     => [],
  also      => 'Moose',
);

1;