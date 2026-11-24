# Check that pg_createcluster forwards complete ICU rules to initdb.

use strict;
use warnings;

use lib 't';
use TestLib;
use PgCommon;
use IPC::Run qw(run);
use Test::More;

my @versions = grep { $_ >= 16 } @MAJORS;
plan skip_all => 'initdb --icu-rules requires PostgreSQL 16 or later'
    unless @versions;

sub command_ok {
    my ($argv, $description) = @_;
    my ($stdout, $stderr);
    my $success = run $argv, \undef, \$stdout, \$stderr;
    ok $success, $description;
    diag $stdout . $stderr unless $success;
    return ($success, $stdout);
}

my @cleanup;
END {
    local $?;
    system 'pg_dropcluster', '--stop', @$_ foreach @cleanup;
}

my $singleline = '&a < c < b';
# Include quotes, UTF-8, CRLF, and more than 8 KiB of whitespace. The
# leading/trailing newlines also check that argument boundaries survive.
my $multiline = "&a < '\$' < c < b\r\n&c < \xc3\xa9" . (' ' x 9000) . "\n";
my @cases = (
    ['singleline', ["--icu-rules=$singleline"], $singleline],
    ['multiline-equals', ["--icu-rules=$multiline"], $multiline],
    ['multiline-separate', ['--icu-rules', "\n$multiline"], "\n$multiline"],
);

foreach my $v (@versions) {
    foreach my $case (@cases) {
        my ($name, $options, $rules) = @$case;
        my $cluster = "icurules-$name";
        BAIL_OUT "test cluster $v/$cluster already exists"
            if cluster_exists $v, $cluster;
        my ($created) = command_ok ['pg_createcluster', '--start', '--no-status',
            '--locale=C', '--encoding=UTF8', $v, $cluster, '--',
            '--locale-provider=icu', '--icu-locale=en-US',
            '--auth-local=trust', '--auth-host=reject', '--no-sync', @$options],
            "$v $name: create cluster";
        # Initialization may succeed even when the subsequent start fails.
        my $exists = cluster_exists $v, $cluster;
        push @cleanup, [$v, $cluster] if $exists;

        SKIP: {
            skip 'cluster creation failed', 2 unless $created;
            my %info = cluster_info $v, $cluster;
            my $owner = getpwuid $info{'owneruid'};
            my $hex = unpack 'H*', $rules;
            # Compare exact bytes in both templates before any upgrade:
            # pg_upgrade's SQL restore could otherwise mask truncation.
            my ($queried, $output) = command_ok [get_program_path('psql', $v),
                '-X', '--no-password', '-U', $owner, '-h', $info{'socketdir'},
                '-p', $info{'port'}, '-d', 'postgres', '-At',
                '-v', 'ON_ERROR_STOP=1', '-c',
                "SELECT datname, convert_to(daticurules, 'UTF8') = decode('$hex', 'hex') " .
                "FROM pg_database WHERE datname IN ('template0', 'template1') ORDER BY datname"],
                "$v $name: read initialized template rules";
            is $output, "template0|t\ntemplate1|t\n",
                "$v $name: preserve complete rules in both templates";
        }

        if ($exists) {
            my ($dropped) = command_ok ['pg_dropcluster', '--stop', $v, $cluster],
                "$v $name: drop cluster";
            pop @cleanup if $dropped;
        }
    }
}

done_testing();

# vim: filetype=perl
