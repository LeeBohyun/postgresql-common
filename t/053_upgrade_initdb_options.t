# Exercise the JSON initialization-options interface through the complete
# pg_upgradecluster command, including configuration migration and hooks.

use strict;
use warnings;

use lib 't';
use TestLib;
use PgCommon;
use File::Temp qw(tempdir);
use IPC::Run qw(run);
use JSON::PP qw(decode_json);
use Test::More;

sub capture {
    my ($command) = @_;
    my ($stdout, $stderr);
    my $success = run $command, \undef, \$stdout, \$stderr;
    return ($success, $stdout, $stderr);
}

sub run_ok {
    my ($description, @command) = @_;
    my ($success, $stdout, $stderr) = capture(\@command);
    ok $success, $description;
    BAIL_OUT "$description: $stdout$stderr" unless $success;
    return $stdout;
}

my $newversion = $MAJORS[-1];
my @oldversions = grep { $_ >= 14 && $_ < $newversion } @MAJORS;
plan skip_all => 'requires two installed PostgreSQL versions, source 14 or later'
    unless @oldversions;
my $pg_upgrade = get_program_path 'pg_upgrade', $newversion;
plan skip_all => 'target pg_upgrade is not installed' unless $pg_upgrade;
my ($help_ok, $help) = capture([$pg_upgrade, '--help']);
plan skip_all => 'target pg_upgrade does not support printing JSON initdb options'
    unless $help_ok && $help =~ /--print-initdb-options/ && $help =~ /--initdb-database/;

my $state = tempdir('upgrade-initdb-options.XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $hookdir = "$PgCommon::common_confdir/pg_upgradecluster.d";
my $hook = "$hookdir/initdb-options-test";
my $hook_created;
my @cleanup;
END {
    local $?;
    unlink $hook if $hook_created;
    foreach my $cluster (reverse @cleanup) {
        system 'pg_dropcluster', '--stop', @$cluster
            if cluster_exists @$cluster;
    }
}
BAIL_OUT "test hook $hook already exists" if -e $hook;
mkdir $hookdir unless -d $hookdir;
open my $hookfile, '>', $hook or BAIL_OUT "create $hook: $!";
$hook_created = 1;
print $hookfile <<'HOOK';
#!/usr/bin/perl
use strict;
use warnings;
use PgCommon;
use JSON::PP qw(decode_json encode_json);

my ($oldversion, $cluster, $newversion, $phase) = @ARGV;
exit 0 unless $cluster =~ /^printopts-/;
my %info = cluster_info $newversion, $cluster;
my $started;
if ($phase eq 'init' && !$info{'running'}) {
    # Configuration copying has finished, and hooks can set a preload before
    # the new server is started for either inspection or pg_upgrade.
    PgCommon::set_conf_value($newversion, $cluster, 'postgresql.conf',
        'shared_preload_libraries', 'plpgsql');
    system('pg_ctlcluster', $newversion, $cluster, 'start') == 0 or die 'start target';
    $started = 1;
}
my $owner = getpwuid $info{'owneruid'};
open my $query, '-|', get_program_path('psql', $newversion), '-X', '-At',
    '-h', $info{'socketdir'}, '-p', $info{'port'}, '-U', $owner, '-d', 'postgres',
    '-v', 'ON_ERROR_STOP=1', '-c',
    q{SELECT json_build_object(
        'wal', current_setting('wal_segment_size'),
        'checksums', current_setting('data_checksums'),
        'copied', current_setting('custom.printer_test', true),
        'preload', current_setting('shared_preload_libraries'),
        'ctype', (SELECT datctype FROM pg_database WHERE datname = 'template1'),
        'rules', (SELECT json_object_agg(datname, encode(convert_to(daticurules, 'UTF8'), 'hex'))
                  FROM pg_database WHERE datname IN ('template0', 'template1')))}
    or die "start psql: $!";
local $/;
my $result = <$query>;
close $query or die 'query target';
open my $record, '>>', $ENV{'PG_INITDB_OPTIONS_TEST_STATE'} or die "write state: $!";
print $record encode_json({phase => $phase, values => decode_json($result)}), "\n";
close $record or die "close state: $!";
if ($started) {
    system('pg_ctlcluster', $newversion, $cluster, 'stop') == 0 or die 'stop target';
}
HOOK
close $hookfile or BAIL_OUT "close $hook: $!";
chmod 0755, $hook or BAIL_OUT "chmod $hook: $!";

sub query {
    my ($version, $cluster, $sql) = @_;
    my %info = cluster_info $version, $cluster;
    my $owner = getpwuid $info{'owneruid'};
    my ($success, $stdout, $stderr) = capture([
        get_program_path('psql', $version), '-X', '-At', '-h', $info{'socketdir'},
        '-p', $info{'port'}, '-U', $owner, '-d', 'postgres', '-v', 'ON_ERROR_STOP=1',
        '-c', $sql]);
    BAIL_OUT "query $version/$cluster: $stdout$stderr" unless $success;
    chomp $stdout;
    return $stdout;
}

sub create_source {
    my ($oldversion, $targetversion, $name, $wal, $encoding, $icu) = @_;
    foreach my $version ($oldversion, $targetversion) {
        BAIL_OUT "test cluster $version/$name already exists" if cluster_exists $version, $name;
        push @cleanup, [$version, $name];
    }
    run_ok "create $name source", 'pg_createcluster', '--no-status', '--locale=C',
        "--encoding=$encoding", $oldversion, $name, '--', "--wal-segsize=$wal",
        '--auth-local=trust', '--auth-host=reject',
        ($oldversion >= 18 ? '--no-data-checksums' : ()),
        ($icu ? ('--locale-provider=icu', '--icu-locale=en-US', '--icu-rules=&a < c < b') : ());
    my %info = cluster_info $oldversion, $name;
    chown $info{'owneruid'}, $info{'ownergid'}, $state if $> == 0;
    PgCommon::set_conf_value($oldversion, $name, 'postgresql.conf',
        'custom.printer_test', 'copied-before-init-hook');
    run_ok "start $name source", 'pg_ctlcluster', $oldversion, $name, 'start';
    query $oldversion, $name, 'CREATE TABLE t (id int PRIMARY KEY); INSERT INTO t VALUES (1), (2), (3)';
}

sub upgrade_case {
    my ($name, $oldversion, $targetversion, $encoding, $rules, $mode, $tmpdir) = @_;
    my $cluster = "printopts-$name";
    my $wal = $mode eq 'override' || $mode eq 'fallback' || $mode eq 'dump' ? 16 : 2;
    create_source($oldversion, $targetversion, $cluster, $wal, $encoding, defined $rules);
    if (defined $rules) {
        my $hex = unpack 'H*', $rules;
        query $oldversion, $cluster,
            "UPDATE pg_database SET daticurules = convert_from(decode('$hex', 'hex'), 'UTF8') " .
            "WHERE datname = 'template1'";
    }
    # Exercise both existing source states. Printer discovery must leave a
    # stopped source stopped and must not require Debian's locale query/start.
    run_ok "stop $name source", 'pg_ctlcluster', $oldversion, $cluster, 'stop'
        if $mode eq 'stopped';
    local $ENV{'PG_INITDB_OPTIONS_TEST_STATE'} = "$state/$name.jsonl";
    my $output;
    {
        local $ENV{'TMPDIR'} = defined $tmpdir ? $tmpdir : $ENV{'TMPDIR'};
        # An inherited override would hide a bad TMPDIR-derived socket path.
        local $ENV{'PGSOCKETDIR'};
        delete $ENV{'PGSOCKETDIR'};
        $output = run_ok "complete $name upgrade", 'pg_upgradecluster',
            '-v', $targetversion, '--method=' . ($mode eq 'dump' ? 'dump' : 'upgrade'),
            '--force-packages', '--start',
            ($mode eq 'override' ? '--locale=C.UTF-8' : ()), $oldversion, $cluster;
    }
    like $output, qr/Success\. Please check/, "$name reports success";
    is query($targetversion, $cluster, 'SELECT array_agg(id ORDER BY id) FROM t'),
        '{1,2,3}', "$name preserves source rows";
    open my $records, '<', $ENV{'PG_INITDB_OPTIONS_TEST_STATE'} or BAIL_OUT "read hook records: $!";
    my @records = map { decode_json($_) } <$records>;
    close $records;
    is_deeply [map { $_->{'phase'} } @records], ['init', 'finish'],
        "$name runs init and finish hooks around the upgrade";
    is $records[0]->{'values'}->{'copied'}, 'copied-before-init-hook',
        "$name copies configuration before the init hook";
    is $records[0]->{'values'}->{'preload'}, $mode eq 'dump' ? '' : 'plpgsql',
        "$name preserves the method's startup and preload timing";
    is $records[0]->{'values'}->{'wal'}, "${wal}MB",
        "$name initializes the expected WAL segment size before upgrade";
    is $records[0]->{'values'}->{'checksums'}, $mode eq 'dump' && $targetversion >= 18 ? 'on' : 'off',
        "$name preserves upgrade or dump checksum policy";
    if (defined $rules) {
        # Checking here prevents pg_upgrade's later SQL restoration from
        # hiding a truncated argument or selection of template0's rules.
        is_deeply $records[0]->{'values'}->{'rules'},
            {map { $_ => unpack('H*', $rules) } ('template0', 'template1')},
            "$name initializes both templates with complete maintenance-database rules";
    }
    if ($mode eq 'override') {
        is $records[0]->{'values'}->{'ctype'}, 'C.UTF-8',
            'an explicit locale override takes precedence over discovered settings';
    }
}

upgrade_case('stopped', $oldversions[0], $newversion, 'UTF8', undef, 'stopped');

# Root may use a private temporary directory that is inaccessible after the
# printer drops to the source owner. The upgrade must still preserve data,
# nondefault source settings, and the configuration/hook workflow above.
SKIP: {
    skip 'requires root invocation to exercise privilege dropping', 1 unless $> == 0;
    my $private_tmpdir = tempdir('root-tmp.XXXXXX', DIR => $state, CLEANUP => 1);
    my @permissions = stat $private_tmpdir;
    is $permissions[4], 0, 'private TMPDIR fixture is owned by root';
    is $permissions[2] & 0777, 0700, 'private TMPDIR fixture excludes the source owner';
    upgrade_case('root-private-tmp', $oldversions[0], $newversion,
        'UTF8', undef, 'running', $private_tmpdir);
}

# A writable caller TMPDIR can contain a comma even though libpq interprets
# commas as host separators. A stopped source must use its configured socket.
my $comma_tmpdir = "$state/comma,tmp";
mkdir $comma_tmpdir, 0700 or BAIL_OUT "create $comma_tmpdir: $!";
if ($> == 0) {
    my @owner = stat $state;
    chown $owner[4], $owner[5], $comma_tmpdir or BAIL_OUT "chown $comma_tmpdir: $!";
}
upgrade_case('comma-tmp', $oldversions[0], $newversion,
    'UTF8', undef, 'stopped', $comma_tmpdir);

my ($icu_version) = grep { $_ >= 16 } @oldversions;
my $icu = defined $icu_version;
if ($icu) {
    foreach my $version ($icu_version, $newversion) {
        my ($ok, $configure) = capture([get_program_path('pg_config', $version), '--configure']);
        $icu &&= $ok && $configure !~ /--(?:without-icu|with-icu=no)\b/;
    }
}
SKIP: {
    skip 'requires source and target ICU support and a PG16 or later source', 3 unless $icu;
    my $rules = "&a < '\$' < c < b\r\n&c < \xc3\xa9" . (' ' x 9000) . "\n";
    upgrade_case('icu', $icu_version, $newversion, 'UTF8', $rules, 'running');
    upgrade_case('latin1', $icu_version, $newversion, 'LATIN1', $rules, 'running');
    upgrade_case('win1252', $icu_version, $newversion, 'WIN1252', $rules, 'running');
}
upgrade_case('override', $oldversions[0], $newversion, 'UTF8', undef, 'override');
upgrade_case('dump', $oldversions[0], $newversion, 'UTF8', undef, 'dump');
foreach my $targetversion (reverse @oldversions) {
    next if $targetversion < 16 || $targetversion == $oldversions[0];
    my $binary = get_program_path 'pg_upgrade', $targetversion;
    next unless $binary;
    my ($ok, $options) = capture([$binary, '--help']);
    next unless $ok && $options !~ /--print-initdb-options/;
    upgrade_case('fallback', $oldversions[0], $targetversion, 'UTF8', undef, 'fallback');
    last;
}

my $failed = 'printopts-failed';
create_source($oldversions[0], $newversion, $failed, 2, 'UTF8', 0);
foreach my $running (1, 0) {
    my $label = $running ? 'running' : 'stopped';
    run_ok 'stop the failure-case source', 'pg_ctlcluster', $oldversions[0], $failed, 'stop'
        unless $running;
    my $start_time = query($oldversions[0], $failed, 'SELECT pg_postmaster_start_time()')
        if $running;
    my ($success, $stdout, $stderr);
    {
        local $ENV{'TMPDIR'} = $comma_tmpdir;
        local $ENV{'PGSOCKETDIR'};
        delete $ENV{'PGSOCKETDIR'};
        ($success, $stdout, $stderr) = capture(['pg_upgradecluster', '-v', $newversion,
            '--method=upgrade', '--force-packages', '--maintenance-db=missing_print_options_db',
            $oldversions[0], $failed]);
    }
    ok !$success, "$label source: a real printer failure aborts the upgrade";
    like $stderr, qr/missing_print_options_db.*does not exist/,
        "$label source: the discovery error is reported";
    ok !cluster_exists($newversion, $failed), "$label source: failed discovery creates no target";
    # A usable caller TMPDIR must be honored, rather than always discarded.
    my ($workspace) = $stderr =~ /Temporary files are retained in "(\Q$comma_tmpdir\E\/pg_upgrade-[^"\r\n]+)"/;
    ok defined $workspace && -d "$workspace/pg_upgrade_output.d",
        "$label source: retained diagnostics use the writable caller TMPDIR";
    if ($running) {
        is query($oldversions[0], $failed, 'SELECT pg_postmaster_start_time()'), $start_time,
            'failed discovery leaves a running source available without a restart';
    } else {
        my %info = cluster_info $oldversions[0], $failed;
        ok !-f "$info{pgdata}/postmaster.pid", 'failed discovery stops its temporary source';
    }
}

done_testing();

# vim: filetype=perl
