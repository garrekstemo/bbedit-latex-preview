#!/usr/bin/perl
#
# Background helper for the LaTeX preview filter.
#
# The filter returns to BBEdit straight away and compiles in the
# background, so the preview page has to fetch the new pages itself when
# the compile is done. This tiny HTTP server, listening only on
# 127.0.0.1, hands the page the two script files the compile writes
# (<key>.state.js and <key>.update.js in the cache folder) and nothing
# else. Every URL has to carry a random token, which only the preview
# pages know, so other programs and web pages can't read the previews.
# It exits when BBEdit quits.
#
# Usage: bbedit-latex-serve.pl <cache folder> <info file>
# The info file gets "<port> <token> <pid>".

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;

my ($root, $info) = @ARGV;
die "usage: $0 <cache folder> <info file>\n" unless defined $info;

my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Listen    => 16,
    ReuseAddr => 1,
    Proto     => 'tcp',
) or die "listen: $!\n";

open my $random, '<', '/dev/urandom' or die "urandom: $!\n";
read $random, my $bytes, 16;
close $random;
my $token = unpack 'H*', $bytes;

open my $out, '>', "$info.tmp" or die "$info: $!\n";
print $out $server->sockport, " $token $$\n";
close $out;
rename "$info.tmp", $info or die "$info: $!\n";

END {
    # Remove the info file only if it is still ours.
    if (open my $in, '<', $info) {
        my $line = <$in> // '';
        close $in;
        unlink $info if $line =~ /^\d+ \Q$token\E /;
    }
}
$SIG{PIPE} = 'IGNORE';
$SIG{TERM} = $SIG{INT} = sub { exit 0 };

my $accept = IO::Select->new($server);
my $checked = time;
while (1) {
    if (time - $checked >= 10) {
        $checked = time;
        last if system('/usr/bin/pgrep', '-xq', 'BBEdit') != 0;
    }
    next unless $accept->can_read(5);
    my $client = $server->accept or next;
    my $request = '';
    my $select = IO::Select->new($client);
    while ($request !~ /\r?\n\r?\n/ && length $request < 8192 && $select->can_read(2)) {
        my $n = sysread $client, $request, 4096, length $request;
        last unless $n;
    }
    my ($name) = $request =~ m{^GET /\Q$token\E/(\d+\.(?:state|update)\.js)(?:\?\S*)? HTTP/};
    my $body;
    if (defined $name && open my $file, '<:raw', "$root/$name") {
        local $/;
        $body = <$file>;
        close $file;
    }
    if (defined $body) {
        print $client "HTTP/1.1 200 OK\r\nContent-Type: text/javascript; charset=utf-8\r\n",
            "Content-Length: ", length($body), "\r\nCache-Control: no-store\r\n",
            "Connection: close\r\n\r\n", $body;
    } else {
        print $client "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    }
    close $client;
}
