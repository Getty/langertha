
requires 'File::ShareDir::ProjectDistDir';
requires 'Future';
requires 'Future::AsyncAwait', '>= 0.66';
requires 'Import::Into';
requires 'JSON::MaybeXS';
requires 'JSON::PP';
requires 'JSON::Schema::Modern', '>= 0.617';
requires 'LWP::Protocol::https';
requires 'MIME::Base64';
requires 'Log::Any';
requires 'Module::Runtime';
requires 'Module::Pluggable';
requires 'Moose';
requires 'MooseX::NonMoose';
requires 'OpenAPI::Modern', '>= 0.089';  # needs v0.089+ for updated evaluator handling
requires 'Path::Tiny';
requires 'Time::HiRes';
requires 'Time::Moment';
requires 'URI';
requires 'YAML::PP';
requires 'YAML::XS';

requires 'Net::Async::MCP';

recommends 'IO::Async::SSL';

on test => sub {
  requires 'Test2::Suite';
  requires 'Module::Runtime';
  requires 'Math::Vector::Similarity';
  requires 'Perl::Critic', '>= 1.156';
  requires 'Test::Perl::Critic';

  # t/93_to_json.t compares every JSON::MaybeXS backend; JSON::XS is the one
  # that is not pulled in transitively, so it is wanted but not required.
  recommends 'JSON::XS';
};
