
requires 'Cpanel::JSON::XS';
requires 'File::ShareDir::ProjectDistDir';
requires 'JSON::MaybeXS';
requires 'JSON::Streaming::Reader';
requires 'LWP::Protocol::https';
requires 'Moose';
requires 'MooseX::NonMoose';
requires 'OpenAPI::Modern';
requires 'WWW::Chain', '0.007';
requires 'YAML::PP';
requires 'YAML::XS';

on test => sub {
  requires 'Test2::Suite';
  requires 'Module::Runtime';
};
