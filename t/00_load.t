#!/usr/bin/env perl

use strict;
use warnings;

use Test2::Bundle::More;
use Module::Runtime qw( use_module );

my @modules = qw(
  Langertha
  Langertha::HTTP::Request::OpenAPI
  Langertha::Prompt::Tooling::Optional
  Langertha::OpenAI
  Langertha::OpenAI::Chat
  Langertha::Ollama
  Langertha::Ollama::Chat
  Langertha::Tool
  Langertha::Message
  Langertha::Messages
  LangerthaX
);

plan(scalar @modules);

for my $module (@modules) {
  eval {
    is(use_module($module), $module, 'Loaded '.$module);
  };
  if ($@) { fail('Loading of module '.$module.' failed with '.$@) }
}

done_testing;
