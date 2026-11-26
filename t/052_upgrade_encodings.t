# Test default and explicit encoding on upgrades

use strict; 

use lib 't';
use TestLib;
use PgCommon;
use Test::More tests => (@MAJORS == 1) ? 1 : 51;

if (@MAJORS == 1) {
        pass 'only one major version installed, skipping upgrade tests';
        exit 0;
}

my $outref;
my $oldv = $MAJORS[0];
my $newv = $MAJORS[-1];

is ((exec_as 0, "pg_createcluster --start --locale=ru_RU $oldv main", $outref), 0,
    "creating ru_RU $oldv cluster");

is ((exec_as 'postgres', 'psql -c "create database latintest" template1', $outref), 0,
    "creating latintest DB with LATIN encoding");
if ($oldv <= '8.3') {
    is ((exec_as 'postgres', 'psql -c "create database asctest encoding = \'SQL_ASCII\'" template1', $outref), 0,
	"creating asctest DB with ASCII encoding");
} else {
    is ((exec_as 'postgres', 'psql -c "create database asctest template = template0 lc_collate = \'C\' lc_ctype = \'C\' encoding = \'SQL_ASCII\'" template1', $outref), 0,
	"creating asctest DB with C locale");
}
if ($oldv >= 15) {
    program_ok 'postgres', 'psql -c "create database icutest template template0 locale_provider icu icu_locale de"', 0, "creating database with ICU locale";
} else {
    program_ok 'postgres', 'psql -c "create database icutest"', 0, "creating placeholder icutest database";
}

# Check the metadata reader before an upgrade can restore rules through SQL.
# Pipes, newlines and non-ASCII text must survive in the client encoding
# requested by the caller.
SKIP: {
    skip 'ICU rules require PostgreSQL 16 or later', 3 if $oldv < 16;
    my $rules = "&a < '\$' < '|' < c < b\r\n&c < \xd0\xb0\n";
    my $hex = unpack 'H*', $rules;
    program_ok 'postgres', "psql -c \"UPDATE pg_database SET daticurules = convert_from(decode('$hex', 'hex'), 'UTF8') WHERE datname = 'icutest'\"", 0,
        'set multiline ICU rules in database encoding';
    local $ENV{'PGCLIENTENCODING'} = 'UTF8';
    is_deeply [get_db_locales($oldv, 'main', 'icutest')], ['ru_RU', 'ru_RU', 'icu', 'de', $rules],
        'locale reader preserves provider, locale and complete rules in the client encoding';
    is $ENV{'PGCLIENTENCODING'}, 'UTF8', 'locale reader preserves client encoding';
}
SKIP: {
    skip 'builtin locales require PostgreSQL 17 or later', 2 if $oldv < 17;
    program_ok 'postgres', q{psql -c "CREATE DATABASE builtintest TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER builtin BUILTIN_LOCALE 'C.UTF-8' LC_COLLATE 'C' LC_CTYPE 'C'"}, 0;
    is_deeply [get_db_locales($oldv, 'main', 'builtintest')], ['C', 'C', 'builtin', 'C.UTF-8', ''],
        'locale reader returns the builtin provider locale';
}

is ((exec_as 'postgres', "printf 'A\\324B' | psql -c \"create table t(x varchar); copy t from stdin\" latintest", $outref), 
    0, 'write LATIN database content to latintest');
is ((exec_as 'postgres', "printf 'A\\324B' | psql -c \"create table t(x varchar); copy t from stdin\" asctest", $outref), 
    0, 'write LATIN database content to asctest');

is_program_out 'postgres', "echo \"select * from t\" | psql -Atq latintest",
    0, "A\324B\n", 'old latintest DB has correctly encoded string';
is_program_out 'postgres', "echo \"select * from t\" | psql -Atq asctest",
    0, "A\324B\n", 'old asctest DB has correctly encoded string';

is ((exec_as 'postgres', 'psql -Atl', $outref), 0, 'psql -Atl on old cluster');
ok ((index $$outref, 'latintest|postgres|ISO_8859_5') >= 0, 'latintest is LATIN encoded');
ok ((index $$outref, 'asctest|postgres|SQL_ASCII') >= 0, 'asctest is ASCII encoded');
if ($oldv >= 15) {
    like $$outref, qr/icutest\|postgres\|ISO_8859_5\|icu\|ru_RU\|ru_RU\|de/, 'icutest has proper icu locale';
} else {
    like $$outref, qr/icutest\|postgres\|ISO_8859_5/, 'icutest is LATIN encoded';
}
ok ((index $$outref, 'template1|postgres|ISO_8859_5') >= 0, 'template1 is LATIN encoded');

# upgrade without specifying locales, should be kept
like_program_out 0, "pg_upgradecluster -v $newv $oldv main", 0, qr/^Success. Please check/m;

is ((exec_as 'postgres', "psql --cluster $newv/main -Atl", $outref), 0, 'psql -Atl on upgraded cluster');
ok ((index $$outref, 'latintest|postgres|ISO_8859_5') >= 0, 'latintest is LATIN encoded');
ok ((index $$outref, 'asctest|postgres|SQL_ASCII') >= 0, 'asctest is ASCII encoded');
if ($oldv >= 15) {
    like $$outref, qr/icutest\|postgres\|ISO_8859_5\|icu\|ru_RU\|ru_RU\|de/, 'icutest has proper icu locale';
} else {
    like $$outref, qr/icutest\|postgres\|ISO_8859_5/, 'icutest is LATIN encoded';
}
ok ((index $$outref, 'template1|postgres|ISO_8859_5') >= 0, 'template1 is LATIN encoded');
is_program_out 'postgres', "echo \"select * from t\" | psql --cluster $newv/main -Atq latintest",
    0, "A\324B\n", 'new latintest DB has correctly encoded string';

is ((system "pg_dropcluster --stop $newv main"), 0, 'dropping upgraded cluster');
is ((system "pg_ctlcluster $oldv main start"), 0, 'restarting old cluster');

# upgrade with explicitly specifying other locale
like_program_out 0, "pg_upgradecluster --locale ru_RU.UTF-8 -v $newv $oldv main", 0, qr/^Success. Please check/m;

is ((exec_as 'postgres', "psql --cluster $newv/main -Atl", $outref), 0, 'psql -Atl on upgraded cluster');
if ($newv >= 11) {
    ok ((index $$outref, 'latintest|postgres|ISO_8859_5') >= 0, 'latintest is still LATIN encoded');
} else {
    like $$outref, qr/latintest\|postgres\|(UTF8|UNICODE)/, 'latintest is now UTF8 encoded';
}
ok ((index $$outref, 'asctest|postgres|SQL_ASCII') >= 0, 'asctest is ASCII encoded');
like $$outref, qr/template1\|postgres\|(UTF8|UNICODE)/, 'template1 is UTF8 encoded';
is_program_out 'postgres', "echo \"select * from t\" | psql --cluster $newv/main -Atq latintest",
    0, ($newv >= 11 ? "A\324B\n": "AдB\n"), 'new latintest DB has correctly encoded string';
# ASCII databases don't do automatic encoding conversion, so this remains LATIN
is_program_out 'postgres', "echo \"select * from t\" | psql --cluster $newv/main -Atq asctest",
    0, "A\324B\n", 'new asctest DB has correctly encoded string';

is ((system "pg_dropcluster --stop $newv main"), 0, 'dropping upgraded cluster');

is ((system "pg_dropcluster $oldv main"), 0, 'dropping old cluster');

check_clean;

# vim: filetype=perl
