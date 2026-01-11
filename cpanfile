
requires 'File::ShareDir::ProjectDistDir';
requires 'Future';
requires 'JSON::MaybeXS';
requires 'JSON::PP';
requires 'LWP::Protocol::https';
requires 'MIME::Base64';
requires 'Module::Runtime';
requires 'Moose';
requires 'MooseX::NonMoose';
requires 'OpenAPI::Modern';
requires 'Path::Tiny';
requires 'Time::HiRes';
requires 'URI';
requires 'YAML::PP';
requires 'YAML::XS';

recommends 'IO::Async';
recommends 'Net::Async::HTTP';

on test => sub {
  requires 'Test2::Suite';
  requires 'Module::Runtime';
};
