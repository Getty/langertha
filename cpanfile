
requires 'File::ShareDir::ProjectDistDir';
requires 'JSON::MaybeXS';
requires 'JSON::PP';
requires 'LWP::Protocol::https';
requires 'Module::Runtime';
requires 'Moose';
requires 'MooseX::ABC';
requires 'MooseX::NonMoose';
requires 'OpenAPI::Modern';
requires 'Path::Tiny';
requires 'Time::HiRes';
requires 'URI';
requires 'YAML::PP';
requires 'YAML::XS';

on test => sub {
  requires 'Test2::Suite';
  requires 'Module::Runtime';
};
