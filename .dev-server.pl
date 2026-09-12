#!/usr/bin/perl
# Minimal static file server for the Vladora pages.
# Perl core only: this machine has no node / working python.
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path);

my $PORT = $ENV{PORT} || 4173;
my $ROOT = abs_path(dirname(abs_path($0)));
my $INDEX = 'index.html';

my %MIME = (
  html => 'text/html; charset=utf-8',
  js   => 'text/javascript; charset=utf-8',
  css  => 'text/css; charset=utf-8',
  json => 'application/json; charset=utf-8',
  svg  => 'image/svg+xml',
  png  => 'image/png',
  jpg  => 'image/jpeg',
  jpeg => 'image/jpeg',
  webp => 'image/webp',
  ico  => 'image/x-icon',
  woff2=> 'font/woff2',
  md   => 'text/plain; charset=utf-8',
  txt  => 'text/plain; charset=utf-8',
  xml  => 'application/xml; charset=utf-8',
);

$| = 1;
# Un client che chiude mentre stiamo scrivendo alza SIGPIPE, che di default
# termina il processo: il server moriva a meta' navigazione.
$SIG{PIPE} = 'IGNORE';
my $srv = IO::Socket::INET->new(
  LocalAddr => '127.0.0.1',
  LocalPort => $PORT,
  Proto     => 'tcp',
  Listen    => 32,
  ReuseAddr => 1,
) or die "cannot bind port $PORT: $!\n";

print "serving $ROOT on http://localhost:$PORT/\n";

sub send_response {
  my ($cli, $status, $type, $body, $head_only) = @_;
  my $len = defined $body ? length($body) : 0;
  print $cli "HTTP/1.1 $status\r\n";
  print $cli "Content-Type: $type\r\n";
  print $cli "Content-Length: $len\r\n";
  print $cli "Cache-Control: no-store\r\n";
  print $cli "Connection: close\r\n\r\n";
  print $cli $body if $len && !$head_only;
}

# Browsers open speculative connections that stay idle, and several requests
# arrive in parallel. One select loop keeps the listener responsive without
# killing sockets that have not spoken yet.
my $sel = IO::Select->new($srv);
my %seen_at;

while (1) {
  my @ready = $sel->can_read(5);

  # drop connections that never sent anything for a minute
  my $now = time;
  for my $s ($sel->handles) {
    next if $s == $srv;
    if ($now - ($seen_at{fileno($s)} || $now) > 60) {
      $sel->remove($s); delete $seen_at{fileno($s)}; close $s;
    }
  }

  for my $sock (@ready) {
    if ($sock == $srv) {
      my $new = $srv->accept or next;
      $new->autoflush(1);
      $sel->add($new);
      $seen_at{fileno($new)} = time;
      next;
    }
    handle_request($sock, $sel, \%seen_at);
  }
}

sub handle_request {
  my ($cli, $sel, $seen) = @_;
  $sel->remove($cli);
  delete $seen->{fileno($cli)};

  my $req = <$cli>;
  unless (defined $req) { close $cli; return; }

  my $hsel = IO::Select->new($cli);
  while ($hsel->can_read(1)) {                                   # drain headers
    my $h = <$cli>;
    last if !defined($h) || $h =~ /^\r?\n$/;
  }

  my ($method, $target) = $req =~ m{^(GET|HEAD)\s+(\S+)\s+HTTP/} ;
  unless ($method) { send_response($cli, '405 Method Not Allowed', 'text/plain', 'method not allowed'); close $cli; return; }

  my $head_only = $method eq 'HEAD';
  (my $path = $target) =~ s/[?#].*$//;
  $path =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
  $path = '/' . $INDEX if $path eq '/';
  $path =~ s{^/+}{};

  # keep every request inside $ROOT
  my $file = abs_path(File::Spec->catfile($ROOT, $path)) || '';
  if (!$file || index($file, $ROOT) != 0 || !-f $file) {
    print "404 $path\n";
    send_response($cli, '404 Not Found', 'text/plain; charset=utf-8', "not found: $path", $head_only);
    close $cli; return;
  }

  my ($ext) = $file =~ /\.([A-Za-z0-9]+)$/;
  my $type = $MIME{lc($ext || '')} || 'application/octet-stream';

  open my $fh, '<:raw', $file or do {
    send_response($cli, '500 Internal Server Error', 'text/plain', 'read error', $head_only);
    close $cli; return;
  };
  my $body = do { local $/; <$fh> };
  close $fh;

  print "200 $path\n";
  send_response($cli, '200 OK', $type, $body, $head_only);
  close $cli;
}
