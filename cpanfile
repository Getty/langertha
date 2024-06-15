
requires 'Cpanel::JSON::XS';
requires 'File::ShareDir::ProjectDistDir';
requires 'JSON::MaybeXS';
requires 'Moose';
requires 'OpenAPI::Modern';
requires 'WWW::Chain';
requires 'YAML::XS';

on test => sub {
  requires 'Test::More';
};
