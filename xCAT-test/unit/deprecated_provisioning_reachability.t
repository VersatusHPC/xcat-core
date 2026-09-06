#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use File::Path qw(mkpath);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..', '..' );

sub slurp {
    my ($rel) = @_;
    my $path = File::Spec->catfile( $repo_root, $rel );
    return unless -r $path;
    open( my $fh, '<', $path ) or die "Unable to read $path: $!";
    my $c = do { local $/; <$fh> };
    close($fh);
    return $c;
}

# Report statements that sit after an unconditional return inside the same
# block. Those are unreachable, which is how the deprecated provisioning paths
# survived in the tree for years after they stopped running.
sub unreachable_after_return {
    my ($source) = @_;
    my @lines = split( /\n/, $source, -1 );
    my @found;
    for my $i ( 0 .. $#lines ) {
        my ($indent) = $lines[$i] =~ /^(\s*)(?:return\s*;|return\s+\d+\s*;)\s*$/;
        next unless defined $indent;
        my $depth = length($indent);
        for my $j ( $i + 1 .. $#lines ) {
            my $next = $lines[$j];
            next if $next =~ /^\s*$/ || $next =~ /^\s*#/;
            my ($ni) = $next =~ /^(\s*)/;
            last if length($ni) < $depth;
            last if $next =~ /^\s*[}\]\)]/;
            push @found, ( $j + 1 ) . ": $next";
            last;
        }
    }
    return @found;
}

my $destiny = slurp('xCAT-server/lib/xcat/plugins/destiny.pm');
my $packimage = slurp('xCAT-server/lib/xcat/plugins/packimage.pm');

plan skip_all => 'destiny.pm or packimage.pm not found'
  unless defined($destiny) && defined($packimage);

my @destiny_dead = unreachable_after_return($destiny);
is_deeply( \@destiny_dead, [], 'destiny.pm has no statements after an unconditional return' );

my @packimage_dead = unreachable_after_return($packimage);
is_deeply( \@packimage_dead, [], 'packimage.pm has no statements after an unconditional return' );

# packimage rejects -o, -p and -a up front, so nothing after that point can ask
# for them again. The old no-imagename branch demanded -o, which could never be
# supplied, and reported that as the error. There is nothing to run for a path
# that must not exist, so this one stays a search of the source.
unlike(
    $packimage,
    qr/Please specify a os version with the -o flag/,
    'packimage no longer asks for an option it rejects earlier'
);

# The rejections themselves have to be run. Matching their text passes on a
# commented out line, which leaves a deprecated state accepted with the words
# that reject it still in the file.
my ($reject) = $destiny =~
  /^(        if \(\$state ne 'osimage'\) \{\n.*?)^        \} else \{/ms;
BAIL_OUT('destiny.pm no longer rejects a state that is not osimage') unless $reject;

my ($options) = $packimage =~
  /^(    GetOptions\(\n.*?^    if \(\$arch or \$osver or \$profile\) \{\n.*?^    \}\n)/ms;
BAIL_OUT('packimage.pm no longer parses its options in one block') unless $options;

my ($imageblock) = $packimage =~ /^(    if \(\@ARGV > 0\) \{\n.*?^    \}\n)/ms;
BAIL_OUT('packimage.pm no longer selects the image in one block') unless $imageblock;

# packimage loads the table module through XCATROOT. Point that at a scratch
# tree so the plugin reaches a table it can be told what to hold.
my $root = tempdir( CLEANUP => 1 );
mkpath( File::Spec->catdir( $root, 'lib', 'perl', 'xCAT' ) );
{
    my $fake = File::Spec->catfile( $root, 'lib', 'perl', 'xCAT', 'Table.pm' );
    open( my $out, '>', $fake ) or die "Unable to write $fake: $!";
    print $out <<'FAKE';
package xCAT::Table;
our %rows;
sub new { my ( $class, $table ) = @_; return bless { table => $table }, $class }
sub getAttribs {
    my ( $self, $keys, @cols ) = @_;
    my $key = ( values %$keys )[0];
    return $rows{ $self->{table} }->{$key};
}
1;
FAKE
    close($out);
}

{
    my $code = join( "\n",
        'package XCATTest::Deprecated;',
        'use strict; use warnings;',
        'use Getopt::Long;',
        'sub reject_deprecated_state {',
        '    my ( $state, $callback ) = @_;',
        $reject,
        '    }',
        '    return 0;',
        '}',
        'sub packimage_options {',
        '    my ( $argv, $callback ) = @_;',
        '    local @ARGV = @$argv;',
        '    my ( $profile, $arch, $osver, $method, $compress, $dotorrent, $nosyncfiles, $help, $version );',
        $options,
        '    return 0;',
        '}',
        'sub packimage_image {',
        '    my ( $argv, $callback ) = @_;',
        '    local @ARGV = @$argv;',
        '    my ( $imagename, $osver, $arch, $profile, $syncfile, $provmethod, $envars, $exlistloc, $destdir );',
        $imageblock,
        '    return 0;',
        '}',
        '1;' );
    eval $code;    ## no critic
    BAIL_OUT("unable to compile the extracted plugin blocks: $@") if $@;
}

# Run one of them and return the exit code and what it reported.
sub reported {
    my ( $code ) = @_;
    my @said;
    my $rc = $code->( sub { push @said, $_[0]; return } );
    my @text = map {
        my $e = $_->{error};
        ref($e) eq 'ARRAY' ? @$e : defined($e) ? ($e) : ();
    } @said;
    return ( $rc, join( ' ', @text ) );
}

my ( $rc, $said ) =
  reported( sub { XCATTest::Deprecated::reject_deprecated_state( 'install', $_[0] ) } );
like( $said, qr/have been deprecated, use "osimage=/,
    'nodeset install is rejected as deprecated' );
( $rc, $said ) =
  reported( sub { XCATTest::Deprecated::reject_deprecated_state( 'netboot', $_[0] ) } );
like( $said, qr/have been deprecated/, 'nodeset netboot is rejected as deprecated' );
( $rc, $said ) =
  reported( sub { XCATTest::Deprecated::reject_deprecated_state( 'statelite', $_[0] ) } );
like( $said, qr/have been deprecated/, 'nodeset statelite is rejected as deprecated' );
( $rc, $said ) =
  reported( sub { XCATTest::Deprecated::reject_deprecated_state( 'osimage', $_[0] ) } );
is( $said, '', 'nodeset osimage is not rejected' );

( $rc, $said ) =
  reported( sub { XCATTest::Deprecated::packimage_options( [ '-o', 'rhels9' ], $_[0] ) } );
is( $rc, 1, 'packimage stops on -o' );
like( $said, qr/-o, -p and -a options are obsoleted/, 'packimage still rejects -o' );
( $rc, $said ) =
  reported( sub { XCATTest::Deprecated::packimage_options( [ '-p', 'compute' ], $_[0] ) } );
is( $rc, 1, 'packimage stops on -p' );
( $rc, $said ) =
  reported( sub { XCATTest::Deprecated::packimage_options( [ '-a', 'x86_64' ], $_[0] ) } );
is( $rc, 1, 'packimage stops on -a' );
( $rc, $said ) =
  reported( sub { XCATTest::Deprecated::packimage_options( ['myimage'], $_[0] ) } );
is( $rc,   0,  'packimage accepts an image name on its own' );
is( $said, '', 'packimage reports nothing for an image name on its own' );

{
    no warnings 'once';    # the plugin reads it, nothing here sets it twice
    local $::XCATROOT = $root;
    ( $rc, $said ) =
      reported( sub { XCATTest::Deprecated::packimage_image( [], $_[0] ) } );
    is( $rc, 1, 'packimage stops when no image is named' );
    like( $said, qr/An image name is required/,
        'packimage reports the missing image name instead' );

    require File::Spec->catfile( $root, 'lib', 'perl', 'xCAT', 'Table.pm' );
    local %xCAT::Table::rows = (
        osimage => {
            diskless => {
                osvers => 'rhels9', osarch => 'x86_64',
                profile => 'compute', provmethod => 'netboot',
            },
            diskful => {
                osvers => 'rhels9', osarch => 'x86_64',
                profile => 'compute', provmethod => 'install',
            },
        },
        linuximage => {
            diskless => { exlist => '/opt/exlist', rootimgdir => '/install/netboot' },
            diskful  => { exlist => '/opt/exlist', rootimgdir => '/install/netboot' },
        },
    );
    ( $rc, $said ) =
      reported( sub { XCATTest::Deprecated::packimage_image( ['diskless'], $_[0] ) } );
    is( $rc,   0,  'a netboot image is accepted' );
    is( $said, '', 'a netboot image is reported as no error' );

    ( $rc, $said ) =
      reported( sub { XCATTest::Deprecated::packimage_image( ['diskful'], $_[0] ) } );
    is( $rc, 1, 'a stateful image is not packed' );
    like( $said, qr/cannot be used to build diskless image/,
        'a stateful image is rejected by its provmethod' );

    ( $rc, $said ) =
      reported( sub { XCATTest::Deprecated::packimage_image( ['nosuch'], $_[0] ) } );
    is( $rc, 1, 'an unknown image is not packed' );
    like( $said, qr/Cannot find image/, 'an unknown image is reported as missing' );
}

done_testing();
