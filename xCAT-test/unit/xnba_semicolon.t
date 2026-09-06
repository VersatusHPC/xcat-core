#!/usr/bin/env perl
use strict;
use warnings;
use File::Temp qw(tempdir);
use Test::More;

my $xnba_path = defined $ENV{XCATROOT} ? "$ENV{XCATROOT}/lib/perl/xCAT_plugin/xnba.pm" : '';
$xnba_path = "xCAT-server/lib/xcat/plugins/xnba.pm"
    unless -f $xnba_path;

plan skip_all => "xnba.pm not found" unless -f $xnba_path;

my $src = do { local $/; open my $fh, '<', $xnba_path or die $!; <$fh> };

# iPXE only treats a standalone ; token as a command separator.
# A ; embedded inside an argument value (e.g. ds=nocloud-net;s=...)
# is NOT split by iPXE's parser. Therefore xnba.pm must NOT escape
# the semicolon — doing so (e.g. \;) would corrupt the value and
# prevent cloud-init from parsing the NoCloud seed URL.
unlike($src, qr/kcmd.*=~.*s\/;/, 'BIOS path does not escape semicolons');
unlike($src, qr/ucmd.*=~.*s\/;/, 'UEFI path does not escape semicolons');

# The kcmdline is passed directly to imgargs without modification
like($src, qr/imgargs kernel.*\$kern->\{kcmdline\}/, 'BIOS kcmdline passed directly to imgargs');

# UEFI nodes must not keep a stale install script when the node moves
# back to boot/standby; otherwise they PXE back into the installer.
like($src, qr/sub _write_uefi_exit_script\b/, 'UEFI local boot helper exists');
like($src, qr/_write_uefi_exit_script\(\$bootloader_root, \$node, \$cref->\{currstate\}\);/, 'boot/local states rewrite UEFI xNBA script');
like($src, qr/print \$ucfg "exit\\n";/, 'UEFI local boot script exits iPXE to firmware');

# SLES 11 advertises EFI stub support, but the live UEFI xNBA path corrupts
# the legacy initrd/root image handoff.  It must keep using elilo.
like($src, qr/sub _use_efistub_for_uefi\b/, 'UEFI EFI-stub selection helper exists');
like($src, qr/sles\?11/, 'SLES 11 UEFI compatibility rule matches sle11 and sles11 images');
like($src, qr/if \(_use_efistub_for_uefi\(\$kern\)\)/, 'UEFI boot path uses compatibility helper before direct EFI-stub boot');

# pxelinux is only needed for multiboot, COMBOOT, and memdisk configurations.
# Missing syslinux must not warn for ordinary direct-kernel nodeset requests.
like($src, qr/sub _requires_pxelinux\b/, 'pxelinux requirement helper exists');
like(
    $src,
    qr/\$::XNBA_pxelinux_required = 1 if \(_requires_pxelinux\(\$kern\)\)/,
    'generated boot configuration records when pxelinux is required'
);
like(
    $src,
    qr/if \(\$::XNBA_pxelinux_required\) \{.*?Unable to find pxelinux\.0/s,
    'missing pxelinux warning is limited to requests that generate a pxelinux chain'
);

# The checks above match the text of xnba.pm, so a helper that is turned into
# a no-op leaves them green. Extract the three helpers and run them.
{
    my %block;
    foreach my $name (qw(_write_uefi_exit_script _use_efistub_for_uefi _requires_pxelinux)) {
        ( $block{$name} ) = $src =~ /^(sub \Q$name\E \{\n.*?^\}\n)/ms;
        BAIL_OUT("$xnba_path no longer defines sub $name") unless $block{$name};
    }

    my $code = join( "\n",
        'package XCATTest::Xnba;',
        'use strict; use warnings;',
        'our $efistub = 1;',
        'sub has_efistub { return $efistub }',
        $block{_write_uefi_exit_script},
        $block{_use_efistub_for_uefi},
        $block{_requires_pxelinux},
        '1;' );
    eval $code;    ## no critic
    BAIL_OUT("unable to compile the extracted xnba.pm helpers: $@") if $@;

    my $dir = tempdir( CLEANUP => 1 );
    XCATTest::Xnba::_write_uefi_exit_script( $dir, 'node1', 'boot' );
    my $script = "$dir/node1.uefi";
    ok( -f $script, 'the UEFI helper writes the per-node xNBA script' );
  SKIP: {
        skip( 'no UEFI script to read', 1 ) unless -f $script;
        my $written = do { local $/; open( my $fh, '<', $script ) or die $!; <$fh> };
        is( $written, "#!gpxe\n#boot\nexit\n",
            'the UEFI script exits iPXE to firmware and records the state' );
    }

    # SLES 11 advertises an EFI stub but must stay on elilo.
    is( XCATTest::Xnba::_use_efistub_for_uefi(
            { kernel => '/install/sles11.3/x86_64/boot/linux' } ),
        0, 'a sles11 image keeps the elilo path' );
    is( XCATTest::Xnba::_use_efistub_for_uefi(
            { kernel => '/install/sle11/x86_64/boot/linux' } ),
        0, 'a sle11 image keeps the elilo path' );
    is( XCATTest::Xnba::_use_efistub_for_uefi(
            { kernel => '/install/rhels9/x86_64/vmlinuz' } ),
        1, 'a kernel with an EFI stub boots directly' );
    {
        no warnings 'once';    # the variable is declared inside the eval above
        local $XCATTest::Xnba::efistub = 0;
        is( XCATTest::Xnba::_use_efistub_for_uefi(
                { kernel => '/install/rhels9/x86_64/vmlinuz' } ),
            0, 'a kernel without an EFI stub keeps the elilo path' );
    }

    is( XCATTest::Xnba::_requires_pxelinux( { kernel => 'xcat/genesis.kernel' } ),
        0, 'a direct kernel boot does not need pxelinux' );
    is( XCATTest::Xnba::_requires_pxelinux( { kernel => 'xcat/multiboot!image' } ),
        1, 'a multiboot kernel needs pxelinux' );
    is( XCATTest::Xnba::_requires_pxelinux( { kernel => 'xcat/chain.c32' } ),
        1, 'a COMBOOT kernel needs pxelinux' );
    is( XCATTest::Xnba::_requires_pxelinux( { kernel => 'xcat/memdisk' } ),
        1, 'a memdisk kernel needs pxelinux' );
    is( XCATTest::Xnba::_requires_pxelinux(undef),
        0, 'a request with no kernel entry does not need pxelinux' );
}

done_testing();
