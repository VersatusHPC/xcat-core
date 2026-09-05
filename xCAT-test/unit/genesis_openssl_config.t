#!/usr/bin/env perl
# Genesis must be able to make a certificate request.
#
# The payload carries openssl and libcrypto, but `openssl req` reads the config file at
# OPENSSLDIR/openssl.cnf and refuses to run without it. getcert loops on that command with
# stderr discarded, so a payload without the config file stops the boot at
# "Getting initial certificate" and prints nothing.

use strict;
use warnings;

use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use Test::More;

my $repo = "$FindBin::Bin/../..";
my $getcert = "$repo/xCAT-genesis-scripts/usr/bin/getcert";
BAIL_OUT("getcert not found at $getcert") unless -f $getcert;

#-----------------------------------------------------------------------------
# getcert reports a certificate request that cannot succeed, instead of looping.
#-----------------------------------------------------------------------------

my $dir = tempdir(CLEANUP => 1);
my $bin = "$dir/bin";
make_path($bin);

# openssl that fails "req" the way a payload with no openssl.cnf fails it, and succeeds
# for every other subcommand.
write_exe("$bin/openssl", <<'SH');
#!/bin/sh
if [ "$1" = "req" ]; then
    echo "Can't open \"/usr/lib/ssl/openssl.cnf\" for reading, No such file or directory" >&2
    exit 1
fi
exit 0
SH

write_exe("$bin/allowcred.awk", "#!/bin/sh\nsleep 60\n");
write_exe("$bin/hostname",     "#!/bin/sh\necho testnode\n");
write_exe("$bin/logger",       "#!/bin/sh\necho \"\$*\" >> $dir/logger.out\n");
write_exe("$bin/sleep",        "#!/bin/sh\nexit 0\n");    # the retry must be bounded by time, not by tries

my $out = "$dir/getcert.out";
my $rc  = system(
    "env PATH='$bin:/usr/bin:/bin' GETCERT_CSR_TIMEOUT=2 " .
    "timeout 60 /bin/bash '$getcert' 192.0.2.1:3001 > '$out' 2>&1"
);
my $status = $rc >> 8;

isnt($status, 124, 'getcert stops on its own when openssl req cannot succeed')
    or diag("getcert ran until the 60s timeout killed it; the retry loop has no bound");
isnt($status, 0, 'getcert exits non-zero when it makes no certificate request');

my $logged = -r "$dir/logger.out" ? slurp("$dir/logger.out") : '';
like($logged, qr/getcert/,
    'getcert logs why it made no certificate request')
    or diag("logger recorded: '$logged'");
like($logged, qr/certkey\.pem|certificate request/,
    'the message names the certificate request that failed');

#-----------------------------------------------------------------------------
# Each dracut module installs the openssl config file into the payload.
#-----------------------------------------------------------------------------

for my $family (qw(ubuntu el)) {
    my $module = "$repo/xCAT-genesis-builder/dracut_105/$family/module-setup.sh";
    SKIP: {
        skip "no dracut_105/$family module in this tree", 1 unless -f $module;
        my $requested = run_install($module, $dir, $family);
        like($requested, qr{openssl\.cnf},
            "dracut_105/$family installs the openssl config file")
            or diag("the $family module never asked for an openssl.cnf; "
                  . "openssl req fails in the payload and getcert makes no request");
    }
}

done_testing();

#-----------------------------------------------------------------------------
# Run the module's install() with every dracut helper replaced by a recorder, so the test
# reads what the module asks the payload to carry.
#-----------------------------------------------------------------------------
sub run_install {
    my ($module, $tmp, $family) = @_;

    my $log    = "$tmp/$family.installed";
    my $driver = "$tmp/$family-driver.sh";
    unlink $log;

    open(my $fh, '>', $driver) or die "open $driver: $!";
    print $fh <<"SH";
set -u
LOG='$log'
: > "\$LOG"
for helper in dracut_install inst inst_simple inst_multiple inst_binary inst_script \\
              inst_symlink inst_dir inst_hook inst_rules instmods; do
    eval "\$helper() { printf '%s\\n' \\"\\\$@\\" >> \\"\\\$LOG\\"; return 0; }"
done
# Anything the module calls that the test host does not have must not stop install().
command_not_found_handle() { return 0; }
moddir='$tmp'
hostonly=''
dracutsysrootdir=''
srcmods=''
. '$module' >/dev/null 2>&1 || true
install >/dev/null 2>&1 || true
SH
    close $fh;

    system("/bin/bash '$driver' >/dev/null 2>&1");
    BAIL_OUT("install() in $module recorded nothing; the driver no longer matches the module")
        unless -s $log;
    return slurp($log);
}

sub write_exe {
    my ($path, $body) = @_;
    open(my $fh, '>', $path) or die "open $path: $!";
    print $fh $body;
    close $fh;
    chmod 0755, $path;
}

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or return '';
    local $/;
    my $content = <$fh>;
    close $fh;
    return defined $content ? $content : '';
}
