package Test::MockAsyncHTTP;
# Mock HTTP transport for testing async Langertha engines
# Same pattern as p5-net-async-hetzner's Test::MockAsyncHTTP

use strict;
use warnings;

use Future;
use HTTP::Response;
use JSON::MaybeXS;

sub new {
  my ($class, %args) = @_;
  bless {
    responses => $args{responses} // [],
    requests  => [],
    call_idx  => 0,
  }, $class;
}

sub do_request {
  my ($self, %args) = @_;
  push @{$self->{requests}}, $args{request};

  my $idx = $self->{call_idx}++;
  my $mock = $self->{responses}[$idx] // $self->{responses}[-1];

  return Future->done($mock) if ref($mock) eq 'HTTP::Response';

  # Accept hashref format too: { status => 200, content => '...' }
  my $http_res = HTTP::Response->new(
    $mock->{status} // 200,
    $mock->{reason} // 'OK',
  );
  $http_res->content($mock->{content} // '');
  $http_res->header('Content-Type' => $mock->{content_type} // 'application/json');
  return Future->done($http_res);
}

sub requests { @{$_[0]->{requests}} }
sub request_count { scalar @{$_[0]->{requests}} }

sub mock_json_response {
  my ($class, $data, %opts) = @_;
  my $http_res = HTTP::Response->new($opts{status} // 200, $opts{reason} // 'OK');
  $http_res->content(encode_json($data));
  $http_res->header('Content-Type' => 'application/json');
  return $http_res;
}

1;
