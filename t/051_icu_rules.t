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

my $rules = "&a < '\$' < c < b\r\n&c < \xc3\xa9\n";
my $hex = unpack 'H*', $rules;

foreach my $v (@versions) {
    foreach my $options (["--icu-rules=$rules"], ['--icu-rules', $rules]) {
        my $form = @$options == 1 ? 'equals' : 'separate';
        my $cluster = 'icurules';
        BAIL_OUT "test cluster $v/$cluster already exists"
            if cluster_exists $v, $cluster;
        my ($stdout, $stderr);
        my $created = run ['pg_createcluster', '--start', '--no-status',
            '--locale=C', '--encoding=UTF8', $v, $cluster, '--',
            '--locale-provider=icu', '--icu-locale=en-US', @$options],
            \undef, \$stdout, \$stderr;
        ok $created, "$v $form: create cluster";
        diag $stdout . $stderr unless $created;

        SKIP: {
            skip 'cluster creation failed', 2 unless $created;
            # Compare exact bytes in both templates before any upgrade:
            # pg_upgrade's SQL restore could otherwise mask truncation.
            is_program_out 'postgres', "psql --cluster $v/$cluster -XAt -c \"" .
                "SELECT datname, convert_to(daticurules, 'UTF8') = decode('$hex', 'hex') " .
                "FROM pg_database WHERE datname IN ('template0', 'template1') ORDER BY datname\"",
                0, "template0|t\ntemplate1|t\n", "$v $form: preserve complete rules in both templates";
        }

        program_ok 0, "pg_dropcluster --stop $v $cluster", 0
            if cluster_exists $v, $cluster;
    }
}

done_testing();

# vim: filetype=perl
