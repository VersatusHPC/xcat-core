#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

# rmcmon runs mkrmcresources as an external command, so the resource files it
# loads with require get the @INC of a fresh process. A resource file that needs
# an xCAT module can only find one if mkrmcresources puts $XCATROOT/lib/perl on
# @INC before it loads anything. Eight resource files under xCAT-rmc/resources
# use xCAT::Utils.

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..', '..' );
my $script =
  File::Spec->catfile( $repo_root, 'xCAT-rmc', 'scripts', 'mkrmcresources' );

die "Unable to find mkrmcresources at $script" unless -f $script;

sub write_file {
    my ( $path, $contents ) = @_;

    open( my $fh, '>', $path ) or die "Unable to write $path: $!";
    print {$fh} $contents;
    close($fh) or die "Unable to close $path: $!";

    return;
}

#---------------------------------------------------------------------------
# Builds a scratch resource tree in the layout traverseDirectories expects:
# <basedir>/<resource class>/<resource name>.pm. The resource file carries no
# "use lib" of its own, so only mkrmcresources can make the xCAT module
# reachable. The resource records that it compiled by writing the marker file.
#---------------------------------------------------------------------------
sub stage_resources {
    my (%args) = @_;

    my $root = tempdir( CLEANUP => 1 );

    my $module_dir =
      File::Spec->catdir( $root, 'xcatroot', 'lib', 'perl', 'xCAT' );
    make_path($module_dir);
    write_file(
        File::Spec->catfile( $module_dir, 'Stub.pm' ),
        "package xCAT::Stub;\nsub answer { return 'stub' }\n1;\n"
    );

    my $class_dir = File::Spec->catdir( $root, 'resources', 'IBM.Sensor' );
    make_path($class_dir);

    my $body = '';
    $body .= "use xCAT::Stub;\n" if $args{needs_xcat_module};
    $body .= <<'RESOURCE';
$RES::Sensor{'TestSensor'} = {
    Name     => q(TestSensor),
    Command  => q(/bin/true),
    UserName => q(root),
};

open( my $marker_fh, '>', $ENV{RMC_TEST_MARKER} )
  or die "Unable to write the marker: $!";
print {$marker_fh} 'loaded';
close($marker_fh);

1;
RESOURCE

    write_file( File::Spec->catfile( $class_dir, 'TestSensor.pm' ), $body );

    return $root;
}

#---------------------------------------------------------------------------
# Runs mkrmcresources over the staged tree with an empty PERL5LIB, so the only
# thing that can put the staged XCATROOT on @INC is mkrmcresources itself.
# traverseDirectories runs before the first RSCT command, so the marker is
# written whether or not RSCT is installed.
#---------------------------------------------------------------------------
sub run_mkrmcresources {
    my ($root) = @_;

    my $marker = File::Spec->catfile( $root, 'loaded.marker' );

    local $ENV{XCATROOT}        = File::Spec->catdir( $root, 'xcatroot' );
    local $ENV{RMC_TEST_MARKER} = $marker;
    local $ENV{PERL5LIB}        = q{};

    my $command = sprintf( '%s %s %s 2>&1',
        $^X, $script, File::Spec->catdir( $root, 'resources' ) );
    my $output = `$command`;

    return ( ( -e $marker ? 1 : 0 ), $output );
}

{
    my ( $loaded, $output ) =
      run_mkrmcresources( stage_resources( needs_xcat_module => 0 ) );
    ok( $loaded,
        'mkrmcresources loads a resource file that needs no xCAT module' )
      or diag($output);
}

{
    my ( $loaded, $output ) =
      run_mkrmcresources( stage_resources( needs_xcat_module => 1 ) );
    ok( $loaded,
        'mkrmcresources loads a resource file that uses an xCAT module' )
      or diag($output);
}

done_testing();
