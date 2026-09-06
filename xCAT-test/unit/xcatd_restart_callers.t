#!/usr/bin/env perl
use strict;
use warnings;

use File::Basename;
use File::Copy;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..', '..' );

sub read_file {
    my ($path) = @_;
    open( my $fh, '<', $path ) or die "Unable to read $path: $!";
    my $contents = do { local $/; <$fh> };
    close($fh);
    return $contents;
}

my $unit = read_file(
    File::Spec->catfile( $repo_root, 'xCAT-server', 'etc', 'init.d', 'xcatd.service' )
);
unlike( $unit, qr{/etc/init\.d/xcatd},
    'the native systemd unit does not invoke the legacy script' );
like( $unit, qr{^ExecStart=.*?/usr/sbin/xcatd}m,
    'the native systemd unit starts xcatd directly' );

my $imgport = read_file(
    File::Spec->catfile( $repo_root, 'xCAT-server', 'lib', 'xcat', 'plugins', 'imgport.pm' )
);
like( $imgport, qr{system\("\$::XCATROOT/sbin/restartxcatd"\)},
    'imgport preserves the xcatd fast-restart path' );
unlike( $imgport, qr{xCAT::Utils->restartservice\("xcatd"\)},
    'imgport does not replace a fast restart with a full service restart' );
unlike( $imgport, qr{system\("/etc/init\.d/xcatd},
    'imgport no longer hard-codes the legacy init path' );

my %reload_callers = (
    'xCAT-OpenStack Debian scriptlet' => 'xCAT-OpenStack/debian/postinst',
    'xCAT-rmc Debian scriptlet' => 'xCAT-rmc/debian/postinst',
    'perl-xCAT Debian scriptlet' => 'perl-xCAT/debian/postrm',
);

foreach my $name ( sort keys %reload_callers ) {
    my $caller = read_file(
        File::Spec->catfile( $repo_root, split( '/', $reload_callers{$name} ) )
    );
    like( $caller, qr{/sbin/restartxcatd -r},
        "$name preserves xcatd fast-reload semantics" );
    unlike( $caller, qr{systemctl restart xcatd|/etc/init\.d/xcatd},
        "$name does not perform a full restart or require the legacy init path" );
}

my %restart_callers = (
    'xCAT-OpenStack RPM scriptlet' => 'xCAT-OpenStack/xCAT-OpenStack.spec',
    'xCAT-UI RPM scriptlet' => 'xCAT-UI/xCAT-UI.spec',
);

foreach my $name ( sort keys %restart_callers ) {
    my $caller = read_file(
        File::Spec->catfile( $repo_root, split( '/', $restart_callers{$name} ) )
    );
    like( $caller, qr{/sbin/restartxcatd},
        "$name preserves xcatd fast-restart semantics" );
    unlike( $caller, qr{systemctl restart xcatd|/etc/init\.d/xcatd},
        "$name does not perform a full restart or require the legacy init path" );
}

my $xcatsn_deb = read_file(
    File::Spec->catfile( $repo_root, 'xCATsn', 'debian', 'postinst' )
);
like( $xcatsn_deb,
    qr{systemctl start xcatd\.service.*?elif \[ -x /etc/init\.d/xcatd \]}s,
    'xCATsn Debian starts xcatd under the native service manager' );

my $xcatsn_spec = read_file(
    File::Spec->catfile( $repo_root, 'xCATsn', 'xCATsn.spec' )
);
like( $xcatsn_spec,
    qr{systemctl restart xcatd\.service.*?elif \[ -x /etc/init\.d/xcatd \]}s,
    'xCATsn RPM retains its existing service-node restart with a legacy fallback' );

my $perl_xcat_spec = read_file(
    File::Spec->catfile( $repo_root, 'perl-xCAT', 'perl-xCAT.spec' )
);
unlike( $perl_xcat_spec, qr{/etc/init\.d/xcatd},
    'perl-xCAT upgrade logic no longer assumes the legacy init path exists' );
like( $perl_xcat_spec, qr{\$RPM_INSTALL_PREFIX0/sbin/xcatd},
    'perl-xCAT detects the installed server independently of its init system' );

# The three checks above match the text of imgport.pm, so commenting out the
# restart leaves them green. Run the routine instead: extract make_files and
# the two helpers it calls, then confirm the restart command runs.
{
    my $imgport_path = File::Spec->catfile( $repo_root, 'xCAT-server', 'lib', 'xcat', 'plugins', 'imgport.pm' );
    my %block;
    foreach my $name (qw(make_files copyPostscripts movePlugin)) {
        ( $block{$name} ) = $imgport =~ /^(sub \Q$name\E \{\n.*?^\}\n)/ms;
        BAIL_OUT("$imgport_path no longer defines sub $name") unless $block{$name};
    }
    BAIL_OUT("$imgport_path no longer declares \$hasplugin")
      unless $imgport =~ /^my \$hasplugin = 0;$/m;

    my $tmpdir = tempdir( CLEANUP => 1 );
    local $::XCATROOT = "$tmpdir/xcatroot";
    make_path("$::XCATROOT/lib/perl/xCAT_plugin");
    make_path("$::XCATROOT/sbin");
    my $marker = "$tmpdir/restarted";
    open( my $rfh, '>', "$::XCATROOT/sbin/restartxcatd" )
      or die "Unable to write the restartxcatd stub: $!";
    print {$rfh} "#!/bin/sh\necho restarted >> \"$marker\"\n";
    close($rfh);
    chmod( 0755, "$::XCATROOT/sbin/restartxcatd" );

    # The kit directory carries a plugin, which is what makes imgport restart.
    my $imgdir = "$tmpdir/imgdir";
    make_path("$imgdir/testkit/plugins");
    open( my $pfh, '>', "$imgdir/testkit/plugins/testkit.pm" ) or die $!;
    print {$pfh} "1;\n";
    close($pfh);
    my $kitdest = "$tmpdir/kits";
    make_path($kitdest);

    my $pkg = 'XCATTest::Imgport';
    my $code = join( "\n",
        "package $pkg;",
        'use strict; use warnings;',
        'use File::Basename; use File::Copy; use File::Path qw(mkpath);',
        'my $hasplugin = 0;',
        'sub _hasplugin { return $hasplugin }',
        $block{make_files},
        $block{copyPostscripts},
        $block{movePlugin},
        '1;' );
    {
        no warnings 'redefine';
        local $SIG{__WARN__} = sub { };
        eval $code;    ## no critic
        BAIL_OUT("Unable to compile the extracted imgport routines: $@") if $@;
    }
    no strict 'refs';
    *{'xCAT::TableUtils::getInstallDir'} = sub { return "$tmpdir/install" };
    use strict 'refs';

    my $data = {
        osimage => { provmethod => 'install', osarch => 'x86_64' },
        kit     => { testkit => { kitdir => "$kitdest/testkit" } },
    };
    # make_files prints the cp -rfv output, which is not TAP.
    my $rc;
    {
        open( my $saved, '>&', \*STDOUT ) or die "Unable to save STDOUT: $!";
        open( STDOUT, '>', "$tmpdir/make_files.out" ) or die "Unable to redirect STDOUT: $!";
        $rc = $pkg->can('make_files')->( $data, $imgdir, sub { } );
        open( STDOUT, '>&', $saved ) or die "Unable to restore STDOUT: $!";
    }
    ok( $rc, 'the extracted imgport make_files completes' );
    ok( -e "$::XCATROOT/lib/perl/xCAT_plugin/testkit.pm",
        'imgport installs a plugin shipped inside a kit' );
    ok( -e $marker, 'imgport restarts xcatd after it installs a plugin' );
}

done_testing();
