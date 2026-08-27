#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..', '..' );
my $source_dir = File::Spec->catdir(
    $repo_root,
    qw(xCAT-genesis-builder oe meta-xcat-genesis recipes-core xcat-genesis-console files xcat-genesis-console src)
);
my @plain_sources = map { File::Spec->catfile( $source_dir, $_ ) }
  qw(main.c plain_ui.c shell.c state.c support.c);
my $root = tempdir( CLEANUP => 1 );
my $binary = File::Spec->catfile( $root, 'xcat-genesis-console' );
my $header_test_source = File::Spec->catfile( $root, 'header-test.c' );
my $header_test_binary = File::Spec->catfile( $root, 'header-test' );
my $shell_test_source = File::Spec->catfile( $root, 'shell-test.c' );
my $shell_test_binary = File::Spec->catfile( $root, 'shell-test' );
my $maintenance_shell = File::Spec->catfile( $root, 'maintenance-shell' );
my $compiler = $ENV{CC} || 'cc';

is(
    system(
        $compiler, '-D_POSIX_C_SOURCE=200809L', '-DXCAT_CONSOLE_PLAIN_ONLY',
        '-std=c17', '-Wall', '-Wextra', '-Wpedantic', '-Werror',
        @plain_sources, '-o', $binary
      ) >> 8,
    0,
    'plain console builds with strict warnings'
) or BAIL_OUT('unable to build the console test binary');

sub write_file {
    my ( $path, $contents ) = @_;
    open( my $stream, '>', $path ) or die "Unable to write $path: $!";
    print {$stream} $contents;
    close($stream);
}

sub read_file {
    my ($path) = @_;
    open( my $stream, '<', $path ) or die "Unable to read $path: $!";
    my $contents = do { local $/; <$stream> };
    close($stream);
    return $contents;
}

my $symbol_tool = $ENV{NM};
if ( !defined($symbol_tool) ) {
    ($symbol_tool) = grep { -x $_ }
      map { File::Spec->catfile( $_, 'nm' ) }
      File::Spec->path();
}
SKIP: {
    skip 'nm is unavailable for the console artifact check', 2
      unless $symbol_tool;
    my $symbol_stream;
    unless (open( $symbol_stream, '-|', $symbol_tool, '-u', $binary )) {
        skip "unable to inspect the console test binary: $!", 2;
    }
    my $undefined_symbols = do { local $/; <$symbol_stream> };
    close($symbol_stream);
    is( $? >> 8, 0, 'console undefined symbols are readable' );
    unlike(
        $undefined_symbols,
        qr/(?:^|\s)_?(?:system|popen)(?:@[A-Za-z0-9_.]+)?\s*$/m,
        'console does not delegate commands through a shell',
    );
}

my $newt_probe_source = File::Spec->catfile( $root, 'newt-probe.c' );
write_file(
    $newt_probe_source,
    <<'C'
#include <newt.h>
#include <systemd/sd-journal.h>
int main(void) { return 0; }
C
);
my $newt_probe_status = system(
        $compiler, '-std=c17', '-fsyntax-only', $newt_probe_source,
    ) >> 8;
SKIP: {
    skip 'the newt console build dependencies are unavailable', 3
      if $newt_probe_status != 0 || !$symbol_tool;

    my $newt_object = File::Spec->catfile( $root, 'newt_ui.o' );
    my $newt_build_status = system(
            $compiler, '-D_POSIX_C_SOURCE=200809L', '-std=c17',
            '-Wall', '-Wextra', '-Wpedantic', '-Werror', '-I', $source_dir,
            '-c', File::Spec->catfile( $source_dir, 'newt_ui.c' ),
            '-o', $newt_object,
        ) >> 8;
    is( $newt_build_status, 0,
        'newt console UI builds with strict warnings' );
    skip 'the newt console object did not build', 2
      if $newt_build_status != 0;
    my $newt_symbol_stream;
    unless (open( $newt_symbol_stream, '-|', $symbol_tool, '-u', $newt_object )) {
        skip "unable to inspect the newt console object: $!", 2;
    }
    my $newt_undefined_symbols = do { local $/; <$newt_symbol_stream> };
    close($newt_symbol_stream);
    is( $? >> 8, 0, 'newt console undefined symbols are readable' );
    unlike(
        $newt_undefined_symbols,
        qr/(?:^|\s)_?(?:system|popen)(?:@[A-Za-z0-9_.]+)?\s*$/m,
        'newt console does not delegate commands through a shell',
    );
}

write_file(
    $header_test_source,
    <<'C'
#include "console.h"

#include <assert.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "shell-path") == 0) {
        return strcmp(XCAT_GENESIS_MAINTENANCE_SHELL_PATH,
                      "/usr/libexec/xcat/genesis-maintenance-shell");
    }
    assert(xcat_header_context_columns(0) == 0);
    assert(xcat_header_context_columns(19) == 0);
    assert(xcat_header_context_columns(20) == 0);
    assert(xcat_header_context_columns(21) == 1);
    assert(xcat_header_context_columns(80) == 60);
    return 0;
}
C
);
is(
    system(
        $compiler, '-D_POSIX_C_SOURCE=200809L', '-std=c17', '-Wall', '-Wextra',
        '-Wpedantic', '-Werror', '-I', $source_dir, $header_test_source,
        File::Spec->catfile( $source_dir, 'support.c' ), '-o', $header_test_binary
      ) >> 8,
    0,
    'header bounds test builds with strict warnings'
);
is( system($header_test_binary) >> 8, 0,
    'narrow terminals leave no writable header context' );
is( system($header_test_binary, 'shell-path') >> 8, 0,
    'console defaults to the packaged maintenance shell' );

write_file(
    $shell_test_source,
    <<'C'
#include "console.h"

int main(void) {
    return xcat_run_maintenance_shell();
}
C
);
is(
    system(
        $compiler, '-D_POSIX_C_SOURCE=200809L', '-std=c17', '-Wall', '-Wextra',
        '-Wpedantic', '-Werror',
        qq{-DXCAT_GENESIS_MAINTENANCE_SHELL_PATH="$maintenance_shell"},
        '-I', $source_dir, $shell_test_source,
        File::Spec->catfile( $source_dir, 'shell.c' ),
        File::Spec->catfile( $source_dir, 'support.c' ),
        '-o', $shell_test_binary,
    ) >> 8,
    0,
    'maintenance-shell launcher test builds with strict warnings',
);
write_file($maintenance_shell, "#!/bin/sh\nexit 7\n");
chmod 0755, $maintenance_shell;
is(system($shell_test_binary) >> 8, 0,
    'the launcher accepts the maintenance shell later exit status');
unlink($maintenance_shell) or die "Unable to remove $maintenance_shell: $!";
isnt(system($shell_test_binary) >> 8, 0,
    'the launcher reports a direct exec failure');

my $cmdline = File::Spec->catfile( $root, 'cmdline' );
my $uptime = File::Spec->catfile( $root, 'uptime' );
my $os_release_real = File::Spec->catfile( $root, 'os-release.real' );
my $os_release = File::Spec->catfile( $root, 'os-release' );
my $state_dir = File::Spec->catdir( $root, 'status' );
my $genesis_env = File::Spec->catfile( $root, 'genesis.env' );
my $destiny = File::Spec->catfile( $root, 'destiny' );
my $response = File::Spec->catfile( $root, 'xcat-response.env' );
my $sys_root = File::Spec->catdir( $root, 'sys' );
my $proc_root = File::Spec->catdir( $root, 'proc' );
my $net_root = File::Spec->catdir( $sys_root, 'class', 'net', 'eth0' );
my $dmi_root = File::Spec->catdir( $sys_root, 'class', 'dmi', 'id' );
my $extensions = File::Spec->catdir( $root, 'extensions' );
my $providers = File::Spec->catdir( $root, 'providers' );

make_path(
    $state_dir, $net_root, $dmi_root, $proc_root, $extensions, $providers,
    File::Spec->catdir( $sys_root, 'firmware', 'efi' )
);
write_file( $cmdline,
    "xcatd=192.0.2.10:3001 BOOTIF=01-52-54-00-00-00-01 gateway=192.0.2.1\n" );
write_file( $uptime, "125.90 200.00\n" );
write_file( $os_release_real,
    "NAME=\"xCAT Genesis\"\nVERSION_ID=\"0.1\"\n" );
symlink( $os_release_real, $os_release )
  or die "Unable to create os-release link: $!";
write_file(
    File::Spec->catfile( $state_dir, 'network.env' ),
    "SCHEMA=1\nSTATE=READY\nDETAIL=Management network ready on eth0\n"
      . "STARTED_SECONDS=100\nUPDATED_SECONDS=100\nVERIFIED_SECONDS=100\n"
);
write_file(
    File::Spec->catfile( $state_dir, 'registration.env' ),
    "SCHEMA=1\nSTATE=ACTION_RECEIVED\nDETAIL=Action osimage received\n"
      . "STARTED_SECONDS=110\nUPDATED_SECONDS=120\nVERIFIED_SECONDS=120\n"
      . "NODE_NAME=compute01\nACTION=osimage\nTARGET=rocky9\n"
);
my $extension_ready =
    "SCHEMA=1\nSTATE=READY\nDETAIL=Genesis extensions loaded\n"
      . "STARTED_SECONDS=105\nUPDATED_SECONDS=106\n";
write_file(
    File::Spec->catfile( $state_dir, 'extensions.env' ),
    $extension_ready
);
my $ipv4_network_state =
    "XCATDEST=192.0.2.10:3001\nXCAT_INTERFACE=eth0\n"
      . "XCAT_SOURCE_ADDRESS=192.0.2.20\n"
      . "XCAT_SOURCE_PREFIXED_ADDRESS=192.0.2.20/24\n"
      . "XCAT_GATEWAY=192.0.2.1\nXCAT_DNS_SERVERS=192.0.2.53\n"
      . "XCAT_NETWORK_METHOD=auto\nXCAT_LINK_STATE=up\n"
      . "XCAT_MAC_ADDRESS=52:54:00:00:00:01\n";
write_file( $genesis_env, $ipv4_network_state );
write_file( $destiny, "osimage=rocky9\n" );
write_file( $response, "XCAT_NODE_NAME=compute01\n" );
write_file( File::Spec->catfile( $net_root, 'operstate' ), "up\n" );
write_file( File::Spec->catfile( $net_root, 'address' ),
    "52:54:00:00:00:01\n" );
write_file( File::Spec->catfile( $dmi_root, 'product_serial' ),
    "TEST-SERIAL-001\n" );
write_file( File::Spec->catfile( $dmi_root, 'product_uuid' ),
    "11111111-2222-3333-4444-555555555555\n" );
write_file( File::Spec->catfile( $extensions, 'one.raw' ), '' );
write_file( File::Spec->catfile( $extensions, 'two.raw' ), '' );
symlink( File::Spec->catfile( $extensions, 'one.raw' ),
    File::Spec->catfile( $extensions, 'linked.raw' ) )
  or die "Unable to create extension link: $!";
write_file( File::Spec->catfile( $providers, 'one.json' ), "{}\n" );
write_file( File::Spec->catfile( $providers, 'two.json' ), "{}\n" );
symlink( File::Spec->catfile( $providers, 'one.json' ),
    File::Spec->catfile( $providers, 'linked.json' ) )
  or die "Unable to create provider link: $!";

my %environment = (
    XCAT_CMDLINE_FILE => $cmdline,
    XCAT_UPTIME_FILE  => $uptime,
    XCAT_OS_RELEASE   => $os_release,
    XCAT_STATUS_DIR   => $state_dir,
    XCAT_STATE_FILE   => $genesis_env,
    XCAT_DESTINY_FILE => $destiny,
    XCAT_RESPONSE_FILE => $response,
    XCAT_SYS_ROOT     => $sys_root,
    XCAT_PROC_ROOT    => $proc_root,
    XCAT_EXTENSION_DIR => $extensions,
    XCAT_PROVIDER_DIR => $providers,
);

sub run_console {
    local %ENV = ( %ENV, %environment );
    open( my $stream, '-|', $binary, '--once' )
      or die "Unable to run $binary: $!";
    my $output = do { local $/; <$stream> };
    close($stream);
    return ( $? >> 8, $output );
}

my ( $status, $output ) = run_console();
is( $status, 0, 'plain console renders a status snapshot' );
like( $output,
    qr/^xCAT Genesis \| ACTION_RECEIVED \| in stage 00:00:15$/m,
    'header shows the actual state and stage duration' );
like( $output,
    qr/^node: compute01\nserial: TEST-SERIAL-001$/m,
    'node and hardware serial are separate fields' );
like( $output,
    qr/^interface: eth0\nlink: up\nmethod: DHCP\naddress: 192\.0\.2\.20\/24\nMAC: 52:54:00:00:00:01$/m,
    'network fields use explicit labels and describe automatic setup as DHCP' );
like( $output,
    qr/^xCAT server: 192\.0\.2\.10:3001\nxCAT contact: Action received$/m,
    'xCAT endpoint and contact result are separate fields' );
like( $output,
    qr/^action: Boot assigned image\ntarget: rocky9\nprogress: none$/m,
    'action and target remain distinct' );
unlike( $output, qr/last contact/i,
    'main status omits the redundant contact timer' );
unlike( $output, qr/extensions:|providers:|Linux /,
    'inventory details stay off the main page' );
unlike( $output, qr/\e/, 'plain output has no terminal escapes' );

my $cmdline_without_xcat = $ipv4_network_state;
$cmdline_without_xcat =~ s/^XCATDEST=.*\n//m;
write_file( $genesis_env, $cmdline_without_xcat );
write_file(
    $cmdline,
    ( 'quiet ' x 100 )
      . "xcatd=198.51.100.10:3001 BOOTIF=01-52-54-00-00-00-01\n"
);
( $status, $output ) = run_console();
like( $output, qr/^xCAT server: 198\.51\.100\.10:3001$/m,
    'console reads xCAT parameters after byte 512' );
write_file( $genesis_env, $ipv4_network_state );
write_file( $cmdline,
    "xcatd=192.0.2.10:3001 BOOTIF=01-52-54-00-00-00-01 gateway=192.0.2.1\n" );

write_file(
    File::Spec->catfile( $state_dir, 'extensions.env' ),
    "SCHEMA=1\nSTATE=FAILED\nDETAIL=extension signature verification failed\n"
      . "STARTED_SECONDS=123\nUPDATED_SECONDS=124\n"
      . "CODE=EXTENSION_VERIFICATION_FAILED\n"
      . "RECOVERY=Check extension images, manifests, signatures, and trusted keys\n"
);
( $status, $output ) = run_console();
is( $status, 0, 'plain console renders an extension failure' );
like( $output,
    qr/^error: EXTENSION_VERIFICATION_FAILED: extension signature verification failed$/m,
    'extension verification failures stop the main status' );
like( $output,
    qr/^recovery: Check extension images, manifests, signatures, and trusted keys$/m,
    'extension failures include a recovery hint' );
write_file(
    File::Spec->catfile( $state_dir, 'extensions.env' ),
    $extension_ready
);

write_file(
    $genesis_env,
    "XCATDEST=[2001:db8::10]:3001\nXCAT_INTERFACE=eth0\n"
      . "XCAT_SOURCE_ADDRESS=2001:db8::20\n"
      . "XCAT_SOURCE_PREFIXED_ADDRESS=2001:db8::20/64\n"
      . "XCAT_GATEWAY=2001:db8::1\nXCAT_DNS_SERVERS=2001:db8::53\n"
      . "XCAT_NETWORK_METHOD=auto\nXCAT_LINK_STATE=up\n"
      . "XCAT_MAC_ADDRESS=52:54:00:00:00:01\n"
);
( $status, $output ) = run_console();
is( $status, 0, 'plain console renders an automatic IPv6 network' );
like( $output,
    qr/^method: SLAAC\/DHCPv6\naddress: 2001:db8::20\/64$/m,
    'automatic IPv6 setup has an accurate method label' );

my $static_network_state = $ipv4_network_state;
$static_network_state =~ s/XCAT_NETWORK_METHOD=auto/XCAT_NETWORK_METHOD=manual/;
write_file( $genesis_env, $static_network_state );
( $status, $output ) = run_console();
is( $status, 0, 'plain console renders a static network' );
like( $output, qr/^method: Static$/m,
    'manual network setup is labeled Static' );
write_file( $genesis_env, $ipv4_network_state );

write_file(
    File::Spec->catfile( $state_dir, 'action.env' ),
    "SCHEMA=1\nSTATE=RUNNING\nDETAIL=Rebooting into the assigned image\n"
      . "STARTED_SECONDS=122\nUPDATED_SECONDS=124\nVERIFIED_SECONDS=124\n"
      . "ACTION=install\nTARGET=rocky9 install image\n"
);
( $status, $output ) = run_console();
is( $status, 0, 'plain console renders action execution' );
like( $output,
    qr/^xCAT Genesis \| RUNNING \| in stage 00:00:03$/m,
    'action execution becomes the overall state' );
like( $output,
    qr/^action: Install assigned image\ntarget: rocky9 install image\nprogress: none$/m,
    'action status overrides the registration snapshot' );

write_file(
    File::Spec->catfile( $state_dir, 'action.env' ),
    "SCHEMA=1\nSTATE=FAILED\nDETAIL=Unsigned runimage actions are not supported\n"
      . "STARTED_SECONDS=124\nUPDATED_SECONDS=124\n"
      . "CODE=UNSAFE_LEGACY_ACTION\n"
      . "RECOVERY=Package the operation as a signed Genesis system extension\n"
      . "ACTION=runimage\nTARGET=legacy.tgz\n"
);
( $status, $output ) = run_console();
is( $status, 0, 'plain console renders an action failure' );
like( $output,
    qr/^error: UNSAFE_LEGACY_ACTION: Unsigned runimage actions are not supported$/m,
    'action failures remain visible on the main page' );
unlike( $output, qr/^(?:target|progress):/m,
    'failure output uses the same detail rows as the status screen' );

unlink( File::Spec->catfile( $state_dir, 'action.env' ) );
write_file(
    File::Spec->catfile( $state_dir, 'registration.env' ),
    "SCHEMA=1\nSTATE=FAILED\nDETAIL=No valid response from xCAT\n"
      . "STARTED_SECONDS=120\nUPDATED_SECONDS=124\n"
      . "CODE=XCAT_RESPONSE_UNAVAILABLE\n"
      . "RECOVERY=Check xcatd and the management network\n"
);
( $status, $output ) = run_console();
is( $status, 0, 'plain console renders a failed state' );
like( $output,
    qr/^xCAT Genesis \| FAILED \| in stage 00:00:05$/m,
    'failed component becomes the overall state' );
like( $output,
    qr/^error: XCAT_RESPONSE_UNAVAILABLE: No valid response from xCAT$/m,
    'failed component supplies an exact error' );
like( $output,
    qr/^xCAT contact: Failed: No valid response from xCAT$/m,
    'xCAT failure appears on the contact line' );
like( $output,
    qr/^recovery: Check xcatd and the management network$/m,
    'failed component supplies a recovery hint' );

write_file(
    File::Spec->catfile( $state_dir, 'registration.env' ),
    "SCHEMA=1\nSTATE=CONTACTING_XCAT\nDETAIL=xCAT has not answered yet\n"
      . "STARTED_SECONDS=120\nUPDATED_SECONDS=124\n"
      . "ATTEMPT=2\nATTEMPT_LIMIT=6\nNEXT_RETRY_SECONDS=5\n"
);
( $status, $output ) = run_console();
is( $status, 0, 'plain console renders retry progress' );
like( $output,
    qr/^action: Boot assigned image\ntarget: rocky9\nprogress: Attempt 2 of 6; retry in 4s$/m,
    'retry countdown uses structured status fields' );

write_file( $response, "XCAT_NODE_NAME=\n" );
( $status, $output ) = run_console();
is( $status, 0, 'plain console renders an empty node response' );
like( $output, qr/^node: unassigned$/m,
    'an empty node response is shown as unassigned' );

done_testing();
